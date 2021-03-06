// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.
//
// The following only applies to changes made to this file as part of YugaByte development.
//
// Portions Copyright (c) YugaByte, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.  You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software distributed under the License
// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
// or implied.  See the License for the specific language governing permissions and limitations
// under the License.
//

#include "yb/tablet/operations/operation_tracker.h"

#include <algorithm>
#include <limits>
#include <vector>


#include "yb/gutil/map-util.h"
#include "yb/gutil/strings/substitute.h"
#include "yb/tablet/tablet.h"
#include "yb/tablet/tablet_peer.h"
#include "yb/tablet/operations/operation_driver.h"
#include "yb/util/flag_tags.h"
#include "yb/util/logging.h"
#include "yb/util/mem_tracker.h"
#include "yb/util/metrics.h"
#include "yb/util/monotime.h"

DEFINE_int64(tablet_operation_memory_limit_mb, 1024,
             "Maximum amount of memory that may be consumed by all in-flight "
             "operations belonging to a particular tablet. When this limit "
             "is reached, new operations will be rejected and clients will "
             "be forced to retry them. If -1, operation memory tracking is "
             "disabled.");
TAG_FLAG(tablet_operation_memory_limit_mb, advanced);

METRIC_DEFINE_gauge_uint64(tablet, all_operations_inflight,
                           "Operations In Flight",
                           yb::MetricUnit::kOperations,
                           "Number of operations currently in-flight, including any type.");
METRIC_DEFINE_gauge_uint64(tablet, write_operations_inflight,
                           "Write Operations In Flight",
                           yb::MetricUnit::kOperations,
                           "Number of write operations currently in-flight");
METRIC_DEFINE_gauge_uint64(tablet, alter_schema_operations_inflight,
                           "Alter Schema Operations In Flight",
                           yb::MetricUnit::kOperations,
                           "Number of alter schema operations currently in-flight");
METRIC_DEFINE_gauge_uint64(tablet, update_transaction_operations_inflight,
                           "Update Transaction Operations In Flight",
                           yb::MetricUnit::kOperations,
                           "Number of update transaction operations currently in-flight");
METRIC_DEFINE_gauge_uint64(tablet, snapshot_operations_inflight,
                           "Snapshot Operations In Flight",
                           yb::MetricUnit::kOperations,
                           "Number of snapshot operations currently in-flight");
METRIC_DEFINE_gauge_uint64(tablet, truncate_operations_inflight,
                           "Truncate Operations In Flight",
                           yb::MetricUnit::kOperations,
                           "Number of truncate operations currently in-flight");

METRIC_DEFINE_counter(tablet, operation_memory_pressure_rejections,
                      "Operation Memory Pressure Rejections",
                      yb::MetricUnit::kOperations,
                      "Number of operations rejected because the tablet's "
                      "operation memory limit was reached.");

using std::shared_ptr;
using std::vector;

namespace yb {
namespace tablet {

using strings::Substitute;

#define MINIT(x) x(METRIC_##x.Instantiate(entity))
#define GINIT(x) x(METRIC_##x.Instantiate(entity, 0))
OperationTracker::Metrics::Metrics(const scoped_refptr<MetricEntity>& entity)
    : GINIT(all_operations_inflight),
      MINIT(operation_memory_pressure_rejections) {
  operations_inflight[Operation::WRITE_TXN] =
      METRIC_write_operations_inflight.Instantiate(entity, 0);
  operations_inflight[Operation::ALTER_SCHEMA_TXN] =
      METRIC_alter_schema_operations_inflight.Instantiate(entity, 0);
  operations_inflight[Operation::UPDATE_TRANSACTION_TXN] =
      METRIC_update_transaction_operations_inflight.Instantiate(entity, 0);
  operations_inflight[Operation::SNAPSHOT_TXN] =
      METRIC_snapshot_operations_inflight.Instantiate(entity, 0);
  operations_inflight[Operation::TRUNCATE_TXN] =
      METRIC_truncate_operations_inflight.Instantiate(entity, 0);
  static_assert(5 == Operation::kOperationTypes, "Init metrics for all operation types");
}
#undef GINIT
#undef MINIT

OperationTracker::State::State()
  : memory_footprint(0) {
}

OperationTracker::OperationTracker() {
}

OperationTracker::~OperationTracker() {
  std::lock_guard<simple_spinlock> l(lock_);
  CHECK_EQ(pending_operations_.size(), 0);
  if (mem_tracker_) {
    mem_tracker_->UnregisterFromParent();
  }
}

Status OperationTracker::Add(OperationDriver* driver) {
  int64_t driver_mem_footprint = driver->state()->request()->SpaceUsed();
  if (mem_tracker_ && !mem_tracker_->TryConsume(driver_mem_footprint)) {
    if (metrics_) {
      metrics_->operation_memory_pressure_rejections->Increment();
    }

    // May be null in unit tests.
    Tablet* tablet = driver->state()->tablet();

    string msg = Substitute(
        "Operation failed, tablet $0 operation memory consumption ($1) "
        "has exceeded its limit ($2) or the limit of an ancestral tracker",
        tablet ? tablet->tablet_id() : "(unknown)",
        mem_tracker_->consumption(), mem_tracker_->limit());

    YB_LOG_EVERY_N_SECS(WARNING, 1) << msg << THROTTLE_MSG;

    return STATUS(ServiceUnavailable, msg);
  }

  IncrementCounters(*driver);

  // Cache the operation memory footprint so we needn't refer to the request
  // again, as it may disappear between now and then.
  State st;
  st.memory_footprint = driver_mem_footprint;
  std::lock_guard<simple_spinlock> l(lock_);
  CHECK(pending_operations_.emplace(driver, st).second);
  return Status::OK();
}

void OperationTracker::IncrementCounters(const OperationDriver& driver) const {
  if (!metrics_) {
    return;
  }

  metrics_->all_operations_inflight->Increment();
  metrics_->operations_inflight[driver.operation_type()]->Increment();
}

void OperationTracker::DecrementCounters(const OperationDriver& driver) const {
  if (!metrics_) {
    return;
  }

  DCHECK_GT(metrics_->all_operations_inflight->value(), 0);
  metrics_->all_operations_inflight->Decrement();
  DCHECK_GT(metrics_->operations_inflight[driver.operation_type()]->value(), 0);
  metrics_->operations_inflight[driver.operation_type()]->Decrement();
}

void OperationTracker::Release(OperationDriver* driver) {
  DecrementCounters(*driver);

  State st;
  {
    // Remove the operation from the map, retaining the state for use
    // below.
    std::lock_guard<simple_spinlock> l(lock_);
    st = FindOrDie(pending_operations_, driver);
    if (PREDICT_FALSE(pending_operations_.erase(driver) != 1)) {
      LOG(FATAL) << "Could not remove pending operation from map: "
          << driver->ToStringUnlocked();
    }
  }

  if (mem_tracker_) {
    mem_tracker_->Release(st.memory_footprint);
  }
}

std::vector<scoped_refptr<OperationDriver>> OperationTracker::GetPendingOperations() const {
  std::vector<scoped_refptr<OperationDriver>> result;
  {
    std::lock_guard<simple_spinlock> l(lock_);
    result.reserve(pending_operations_.size());
    for (const auto& e : pending_operations_) {
      result.push_back(e.first);
    }
  }
  return result;
}

int OperationTracker::GetNumPendingForTests() const {
  std::lock_guard<simple_spinlock> l(lock_);
  return pending_operations_.size();
}

void OperationTracker::WaitForAllToFinish() const {
  // Wait indefinitely.
  CHECK_OK(WaitForAllToFinish(MonoDelta::FromNanoseconds(std::numeric_limits<int64_t>::max())));
}

Status OperationTracker::WaitForAllToFinish(const MonoDelta& timeout) const {
  const int complain_ms = 1000;
  int wait_time = 250;
  int num_complaints = 0;
  MonoTime start_time = MonoTime::Now();
  while (1) {
    auto operations = GetPendingOperations();

    if (operations.empty()) {
      break;
    }

    MonoDelta diff = MonoTime::Now().GetDeltaSince(start_time);
    if (diff.MoreThan(timeout)) {
      return STATUS(TimedOut, Substitute("Timed out waiting for all operations to finish. "
                                         "$0 operations pending. Waited for $1",
                                         operations.size(), diff.ToString()));
    }
    int64_t waited_ms = diff.ToMilliseconds();
    if (waited_ms / complain_ms > num_complaints) {
      LOG(WARNING) << Substitute("OperationTracker waiting for $0 outstanding operations to"
                                 " complete now for $1 ms", operations.size(), waited_ms);
      num_complaints++;
    }
    wait_time = std::min(wait_time * 5 / 4, 1000000);

    LOG(INFO) << "Dumping currently running operations: ";
    for (scoped_refptr<OperationDriver> driver : operations) {
      LOG(INFO) << driver->ToString();
    }
    SleepFor(MonoDelta::FromMicroseconds(wait_time));
  }
  return Status::OK();
}

void OperationTracker::StartInstrumentation(
    const scoped_refptr<MetricEntity>& metric_entity) {
  metrics_.reset(new Metrics(metric_entity));
}

void OperationTracker::StartMemoryTracking(
    const shared_ptr<MemTracker>& parent_mem_tracker) {
  if (FLAGS_tablet_operation_memory_limit_mb != -1) {
    mem_tracker_ = MemTracker::CreateTracker(
        FLAGS_tablet_operation_memory_limit_mb * 1024 * 1024,
        "operation_tracker",
        parent_mem_tracker);
  }
}

}  // namespace tablet
}  // namespace yb
