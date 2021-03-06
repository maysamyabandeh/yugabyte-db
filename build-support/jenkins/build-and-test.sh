#!/usr/bin/env bash

#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# The following only applies to changes made to this file as part of YugaByte development.
#
# Portions Copyright (c) YugaByte, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied.  See the License for the specific language governing permissions and limitations
# under the License.
#
# This script is invoked from the Jenkins builds to build YB
# and run all the unit tests.
#
# Environment variables may be used to customize operation:
#   BUILD_TYPE: Default: debug
#     Maybe be one of asan|tsan|debug|release|coverage|lint
#
#   YB_BUILD_CPP
#   Default: 1
#     Build and test C++ code if this is set to 1.
#
#   YB_SKIP_BUILD
#   Default: 0
#     Skip building C++ and Java code, only run tests if this is set to 1 (useful for debugging).
#     This option is actually handled by yb_build.sh.
#
#   YB_BUILD_JAVA
#   Default: 1
#     Build and test java code if this is set to 1.
#
#   DONT_DELETE_BUILD_ROOT
#   Default: 0 (meaning build root will be deleted) on Jenkins, 1 (don't delete) locally.
#     Skip deleting BUILD_ROOT (useful for debugging).
#
#   YB_TRACK_REGRESSIONS
#   Default: 0
#     Track regressions by re-running failed tests multiple times on the previous git commit.
#     The implementation of this feature is unfinished.
#
#   YB_COMPILE_ONLY
#   Default: 0
#     Compile the code and build a package, but don't run tests.
#
#   YB_RUN_AFFECTED_TESTS_ONLY
#   Default: 0
#     Try to auto-detect the set of C++ tests to run for the current set of changes relative to
#     origin/master.
#
# Portions Copyright (c) YugaByte, Inc.

set -euo pipefail

. "${BASH_SOURCE%/*}/../common-test-env.sh"

# -------------------------------------------------------------------------------------------------
# Functions

build_cpp_code() {
  # Save the source root just in case, but this should not be necessary as we will typically run
  # this function in a separate process in case it is building code in a non-standard location
  # (i.e. in a separate directory where we rollback the last commit for regression tracking).
  local old_yb_src_root=$YB_SRC_ROOT

  expect_num_args 1 "$@"
  set_yb_src_root "$1"

  heading "Building C++ code in $YB_SRC_ROOT."
  remote_opt=""
  if [[ ${YB_REMOTE_BUILD:-} == "1" ]]; then
    # This helps with our background script resizing the build cluster, because it looks at all
    # running build processes with the "--remote" option as of 08/2017.
    remote_opt="--remote"
  fi

  # Delegate the actual C++ build to the yb_build.sh script. Also explicitly specify the --remote
  # flag so that the worker list refresh script can capture it from ps output and bump the number
  # of workers to some minimum value.
  #
  # We're explicitly disabling third-party rebuilding here as we've already built third-party
  # dependencies (or downloaded them, or picked an existing third-party directory) above.
  time run_build_cmd "$YB_SRC_ROOT/yb_build.sh" $remote_opt \
    --no-rebuild-thirdparty \
    --skip-java \
    "$BUILD_TYPE" 2>&1 | \
    filter_boring_cpp_build_output
  if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    log "C++ build failed!"
    # TODO: perhaps we shouldn't even try to run C++ tests in this case?
    EXIT_STATUS=1
  fi

  log "Finished building C++ code (see timing information above)"

  remove_latest_symlink

  # Restore the old source root. See the comment at the top.
  set_yb_src_root "$old_yb_src_root"
}

cleanup() {
  if [[ -n ${BUILD_ROOT:-} && $DONT_DELETE_BUILD_ROOT == "0" ]]; then
    log "Running the script to clean up build artifacts..."
    "$YB_BUILD_SUPPORT_DIR/jenkins/post-build-clean.sh"
  fi
}

# =================================================================================================
# Main script
# =================================================================================================

cd "$YB_SRC_ROOT"

log "Running with Bash version $BASH_VERSION"
if ! "$YB_BUILD_SUPPORT_DIR/common-build-env-test.sh"; then
  fatal "Test of the common build environment failed, cannot proceed."
fi

export TSAN_OPTIONS=""

if [[ $OSTYPE =~ ^darwin ]]; then
  # This is needed to make sure we're using Homebrew-installed CMake on Mac OS X.
  export PATH=/usr/local/bin:$PATH
fi

MAX_NUM_PARALLEL_TESTS=3

# gather core dumps
ulimit -c unlimited

BUILD_TYPE=${BUILD_TYPE:-debug}
build_type=$BUILD_TYPE
normalize_build_type
readonly build_type

BUILD_TYPE=$build_type
readonly BUILD_TYPE

set_cmake_build_type_and_compiler_type

set_build_root --no-readonly

set_common_test_paths

export YB_DISABLE_LATEST_SYMLINK=1
remove_latest_symlink

run_python_tests

# TODO: deduplicate this with similar logic in yb-jenkins-build.sh.
YB_BUILD_JAVA=${YB_BUILD_JAVA:-1}
YB_BUILD_CPP=${YB_BUILD_CPP:-1}

if is_jenkins && \
   ! is_jenkins_master_build && \
   [[ -z ${YB_RUN_AFFECTED_TESTS_ONLY:-} ]] && \
   ! is_mac; then
  log "Enabling running affected tests only as this seems to be a non-master Jenkins build"
  YB_RUN_AFFECTED_TESTS_ONLY=1
  # Use Make as we can only parse Make's build files to recover the dependency graph.
  YB_USE_NINJA=0
elif [[ ${YB_RUN_AFFECTED_TESTS_ONLY:-0} == "0" ]]; then
  # OK to use Ninja if we don't care about the dependency graph.
  YB_USE_NINJA=1
fi

export YB_RUN_AFFECTED_TESTS_ONLY=${YB_RUN_AFFECTED_TESTS_ONLY:-0}
log "YB_RUN_AFFECTED_TESTS_ONLY=$YB_RUN_AFFECTED_TESTS_ONLY"

export YB_SKIP_BUILD=${YB_SKIP_BUILD:-0}
if [[ $YB_SKIP_BUILD == "1" ]]; then
  export NO_REBUILD_THIRDPARTY=1
fi

if is_jenkins; then
  # Delete the build root by default on Jenkins.
  DONT_DELETE_BUILD_ROOT=${DONT_DELETE_BUILD_ROOT:-0}
else
  log "Not running on Jenkins, not deleting the build root by default."
  # Don't delete the build root by default.
  DONT_DELETE_BUILD_ROOT=${DONT_DELETE_BUILD_ROOT:-1}
fi
YB_SKIP_CPP_COMPILATION=${YB_SKIP_CPP_COMPILATION:-0}
YB_COMPILE_ONLY=${YB_COMPILE_ONLY:-0}

CTEST_OUTPUT_PATH="$BUILD_ROOT"/ctest.log
CTEST_FULL_OUTPUT_PATH="$BUILD_ROOT"/ctest-full.log

# Remove testing artifacts from the previous run before we do anything else. Otherwise, if we fail
# during the "build" step, Jenkins will archive the test logs from the previous run, thinking they
# came from this run, and confuse us when we look at the failed build.

build_root_deleted=false
if [[ $DONT_DELETE_BUILD_ROOT == "0" ]]; then
  if [[ -L $BUILD_ROOT ]]; then
    # If the build root is a symlink, we have to find out what it is pointing to and delete that
    # directory as well.
    build_root_real_path=$( readlink "$BUILD_ROOT" )
    log "BUILD_ROOT ('$BUILD_ROOT') is a symlink to '$build_root_real_path'"
    rm -rf "$build_root_real_path"
    unlink "$BUILD_ROOT"
    build_root_deleted=true
  else
    log "Deleting BUILD_ROOT ('$BUILD_ROOT')."
    ( set -x; rm -rf "$BUILD_ROOT" )
    build_root_deleted=true
  fi
fi

if ! "$build_root_deleted"; then
  log "Skipped deleting BUILD_ROOT ('$BUILD_ROOT'), only deleting $YB_TEST_LOG_ROOT_DIR."
  rm -rf "$YB_TEST_LOG_ROOT_DIR"
fi

if is_jenkins; then
  if "$build_root_deleted"; then
    log "Deleting yb-test-logs from all subdirectories of $YB_BUILD_PARENT_DIR so that Jenkins " \
        "does not get confused with old JUnit-style XML files."
    ( set -x; rm -rf "$YB_BUILD_PARENT_DIR"/*/yb-test-logs )

    log "Deleting old packages from '$YB_BUILD_PARENT_DIR'"
    ( set -x; rm -rf "$YB_BUILD_PARENT_DIR/yugabyte-"*"-$build_type-"*".tar.gz" )
  else
    log "No need to delete yb-test-logs or old packages, build root already deleted."
  fi
fi

if [[ ! -d $BUILD_ROOT ]]; then
  create_dir_on_ephemeral_drive "$BUILD_ROOT" "build/${BUILD_ROOT##*/}"
fi

if [[ -h $BUILD_ROOT ]]; then
  # If we ended up creating BUILD_ROOT as a symlink to an ephemeral drive, now make BUILD_ROOT
  # actually point to the target of that symlink.
  BUILD_ROOT=$( readlink "$BUILD_ROOT" )
fi
readonly BUILD_ROOT
export BUILD_ROOT

TEST_LOG_DIR="$BUILD_ROOT/test-logs"
TEST_TMP_ROOT_DIR="$BUILD_ROOT/test-tmp"

# If we're running inside Jenkins (the BUILD_ID is set), then install an exit handler which will
# clean up all of our build results.
if is_jenkins; then
  trap cleanup EXIT
fi

configure_remote_build

if "$using_default_thirdparty_dir"; then
  find_shared_thirdparty_dir
  if ! "$found_shared_thirdparty_dir"; then
    if [[ ${NO_REBUILD_THIRDPARTY:-} == "1" ]]; then
      log "Skiping third-party build because NO_REBUILD_THIRDPARTY is set."
    else
      log "Starting third-party dependency build"
      time thirdparty/build-thirdparty.sh
      log "Third-party dependency build finished (see timing information above)"
    fi
  fi
else
  log "YB_THIRDPARTY_DIR is explicitly specified as '$YB_THIRDPARTY_DIR', not looking for a" \
      "shared third-party directory."
fi

export NO_REBUILD_THIRDPARTY=1

THIRDPARTY_BIN=$YB_SRC_ROOT/thirdparty/installed/bin
export PPROF_PATH=$THIRDPARTY_BIN/pprof

if which ccache >/dev/null ; then
  CLANG=$YB_BUILD_SUPPORT_DIR/ccache-clang/clang
else
  CLANG=$YB_SRC_ROOT/thirdparty/clang-toolchain/bin/clang
fi

# Configure the build
#

cd "$BUILD_ROOT"

if [[ $YB_RUN_AFFECTED_TESTS_ONLY == "1" ]]; then
  (
    set -x
    # Remove the compilation command file, even if we have not deleted the build root.
    rm -f "$BUILD_ROOT/compile_commands.json"
  )
fi

time run_build_cmd "$YB_SRC_ROOT/yb_build.sh" "$BUILD_TYPE" --cmake-only

# Only enable test core dumps for certain build types.
if [[ $BUILD_TYPE != "asan" ]]; then
  # TODO: actually make this take effect. The issue is that we might not be able to set ulimit
  # unless the OS configuration enables us to.
  export YB_TEST_ULIMIT_CORE=unlimited
fi

# Cap the number of parallel tests to run at $MAX_NUM_PARALLEL_TESTS
detect_num_cpus
if [[ $YB_NUM_CPUS -gt $MAX_NUM_PARALLEL_TESTS ]]; then
  NUM_PARALLEL_TESTS=$MAX_NUM_PARALLEL_TESTS
else
  NUM_PARALLEL_TESTS=$YB_NUM_CPUS
fi

declare -i EXIT_STATUS=0

set +e
if [[ -d /tmp/yb-port-locks ]]; then
  # Allow other users to also run minicluster tests on this machine.
  chmod a+rwx /tmp/yb-port-locks
fi
set -e

FAILURES=""

if [[ $YB_BUILD_CPP == "1" ]] && ! which ctest >/dev/null; then
  fatal "ctest not found, won't be able to run C++ tests"
fi

# -------------------------------------------------------------------------------------------------
# Build C++ code regardless of YB_BUILD_CPP, because we'll also need it for Java tests.

heading "Building C++ code"

if [[ ${YB_TRACK_REGRESSIONS:-} == "1" ]]; then

  cd "$YB_SRC_ROOT"
  if ! git diff-index --quiet HEAD --; then
    fatal "Uncommitted changes found in '$YB_SRC_ROOT', cannot proceed."
  fi
  git_original_commit=$( git rev-parse --abbrev-ref HEAD )

  # Set up a separate directory that is one commit behind and launch a C++ build there in parallel
  # with the main C++ build.

  # TODO: we can probably do this in parallel with running the first batch of tests instead of in
  # parallel with compilation, so that we deduplicate compilation of almost identical codebases.

  YB_SRC_ROOT_REGR=${YB_SRC_ROOT}_regr
  heading "Preparing directory for regression tracking: $YB_SRC_ROOT_REGR"

  if [[ -e $YB_SRC_ROOT_REGR ]]; then
    log "Removing the existing contents of '$YB_SRC_ROOT_REGR'"
    time run_build_cmd rm -rf "$YB_SRC_ROOT_REGR"
    if [[ -e $YB_SRC_ROOT_REGR ]]; then
      log "Failed to remove '$YB_SRC_ROOT_REGR' right away"
      sleep 0.5
      if [[ -e $YB_SRC_ROOT_REGR ]]; then
        fatal "Failed to remove '$YB_SRC_ROOT_REGR'"
      fi
    fi
  fi

  log "Cloning '$YB_SRC_ROOT' to '$YB_SRC_ROOT_REGR'"
  time run_build_cmd git clone "$YB_SRC_ROOT" "$YB_SRC_ROOT_REGR"
  if [[ ! -d $YB_SRC_ROOT_REGR ]]; then
    log "Directory $YB_SRC_ROOT_REGR did not appear right away"
    sleep 0.5
    if [[ ! -d $YB_SRC_ROOT_REGR ]]; then
      fatal "Directory ''$YB_SRC_ROOT_REGR' still does not exist"
    fi
  fi

  cd "$YB_SRC_ROOT_REGR"
  git checkout "$git_original_commit^"
  git_commit_after_rollback=$( git rev-parse --abbrev-ref HEAD )
  log "Rolling back commit '$git_commit_after_rollback', currently at '$git_original_commit'"
  heading "Top commits in '$YB_SRC_ROOT_REGR' after reverting one commit:"
  git log -n 2

  (
    build_cpp_code "$PWD" 2>&1 | \
      while read output_line; do \
        echo "[base version build] $output_line"
      done
  ) &
  build_cpp_code_regr_pid=$!

  cd "$YB_SRC_ROOT"
fi
build_cpp_code "$YB_SRC_ROOT"

if [[ ${YB_TRACK_REGRESSIONS:-} == "1" ]]; then
  log "Waiting for building C++ code one commit behind (at $git_commit_after_rollback)" \
      "in $YB_SRC_ROOT_REGR"
  wait "$build_cpp_code_regr_pid"
fi

log "Disk usage after C++ build:"
show_disk_usage

# End of the C++ code build.
# -------------------------------------------------------------------------------------------------

if [[ $YB_RUN_AFFECTED_TESTS_ONLY == "1" ]]; then
  (
    set -x
    "$YB_SRC_ROOT/python/yb/dependency_graph.py" \
      --build-root "$BUILD_ROOT" self-test --rebuild-graph
  )
fi

# Save the current HEAD commit in case we build Java below and add a new commit. This is used for
# the following purposes:
# - So we can upload the release under the correct commit, from Jenkins, to then be picked up from
#   itest, from the snapshots bucket.
# - For picking up the changeset corresponding the the current diff being tested and detecting what
#   tests to run in Phabricator builds. If we just diff with origin/master, we'll always pick up
#   pom.xml changes we've just made, forcing us to always run Java tests.
current_git_commit=$(git rev-parse HEAD)

# -------------------------------------------------------------------------------------------------
# Java build

if [[ $YB_BUILD_JAVA == "1" && $YB_SKIP_BUILD != "1" ]]; then
  # This sets the proper NFS-shared directory for Maven's local repository on Jenkins.
  set_mvn_parameters

  heading "Building Java code..."
  if [[ -n ${JAVA_HOME:-} ]]; then
    export PATH=$JAVA_HOME/bin:$PATH
  fi
  pushd "$YB_SRC_ROOT/java"

  ( set -x; mvn clean )

  if is_jenkins; then
    # Use a unique version to avoid a race with other concurrent jobs on jar files that we install
    # into ~/.m2/repository.
    random_id=$( date +%Y%m%dT%H%M%S )_$RANDOM$RANDOM$RANDOM
    yb_java_project_version=yugabyte-jenkins-$random_id

    yb_new_group_id=org.yb$random_id
    find . -name "pom.xml" \
           -exec sed -i "s#<groupId>org[.]yb</groupId>#<groupId>$yb_new_group_id</groupId>#g" {} \;

    commit_msg="Updating version to $yb_java_project_version and groupId to $yb_new_group_id "
    commit_msg+="during testing"
    (
      set -x
      mvn versions:set -DnewVersion="$yb_java_project_version"
      git add -A .
      git commit -m "$commit_msg"
    )
    unset commit_msg
  fi

  java_build_cmd_line=( --fail-never -DbinDir="$BUILD_ROOT"/bin )
  if ! time build_yb_java_code_with_retries "${java_build_cmd_line[@]}" \
                                            -DskipTests clean install 2>&1; then
    EXIT_STATUS=1
    FAILURES+=$'Java build failed\n'
  fi
  log "Finished building Java code (see timing information above)"
  popd
fi

# -------------------------------------------------------------------------------------------------
# Now that that all C++ and Java code has been built, test creating a package.
#
# Skip this in ASAN/TSAN, as there are still unresolved issues with dynamic libraries there
# (conflicting versions of the same library coming from thirdparty vs. Linuxbrew) as of 12/04/2017.
#
if [[ ${YB_SKIP_CREATING_RELEASE_PACKAGE:-} != "1" &&
      $build_type != "tsan" &&
      $build_type != "asan" ]]; then
  heading "Creating a distribution package"

  package_path_file="$BUILD_ROOT/package_path.txt"
  rm -f "$package_path_file"

  # We are skipping the Java build here to avoid excessive output, but not skipping the C++ build,
  # because it is invoked with a specific set of targets, which is different from how we build it in
  # a non-packaging context (e.g. for testing).
  #
  # We are passing --build_args="--skip-java" using the "=" syntax, because otherwise "--skip-java"
  # would be interpreted as an argument to yb_release.py, causing an error.
  time "$YB_SRC_ROOT/yb_release" \
    --build "$build_type" \
    --build_root "$BUILD_ROOT" \
    --build_args="--skip-java" \
    --save_release_path_to_file "$package_path_file" \
    --commit "$current_git_commit" \
    --force

  YB_PACKAGE_PATH=$( cat "$package_path_file" )
  if [[ -z $YB_PACKAGE_PATH ]]; then
    fatal "File '$package_path_file' is empty"
  fi
  if [[ ! -f $YB_PACKAGE_PATH ]]; then
    fatal "Package path stored in '$package_path_file' does not exist: $YB_PACKAGE_PATH"
  fi

  # Upload the package, if we have the enterprise-only code in this tree (even if the current build
  # is a community edition build).
  if [[ -d $YB_SRC_ROOT/ent ]]; then
    . "$YB_SRC_ROOT/ent/build-support/upload_package.sh"
    if ! "$package_uploaded" && ! "$package_upload_skipped"; then
      FAILURES+=$'Package upload failed\n'
      EXIT_STATUS=1
    fi
  fi
else
  log "Skipping creating distribution package. Build type: $build_type, OSTYPE: $OSTYPE," \
      "YB_SKIP_CREATING_RELEASE_PACKAGE: ${YB_SKIP_CREATING_RELEASE_PACKAGE:-undefined}."
fi

# -------------------------------------------------------------------------------------------------
# Run tests, either on Spark or locally.
# If YB_COMPILE_ONLY is set to 1, we skip running all tests (Java and C++).

set_asan_tsan_runtime_options

if [[ $YB_COMPILE_ONLY != "1" ]]; then
  if spark_available; then
    if [[ $YB_BUILD_CPP == "1" || $YB_BUILD_JAVA == "1" ]]; then
      log "Will run tests on Spark"
      extra_args=()
      if [[ $YB_BUILD_JAVA == "1" ]]; then
        extra_args+=( "--java" )
      fi
      if [[ $YB_BUILD_CPP == "1" ]]; then
        extra_args+=( "--cpp" )
      fi
      if [[ $YB_RUN_AFFECTED_TESTS_ONLY == "1" ]]; then
        test_conf_path="$BUILD_ROOT/test_conf.json"
        # YB_GIT_COMMIT_FOR_DETECTING_TESTS allows overriding the commit to use to detect the set
        # of tests to run. Useful when testing this script.
        "$YB_SRC_ROOT/python/yb/dependency_graph.py" \
            --build-root "$BUILD_ROOT" \
            --git-commit "${YB_GIT_COMMIT_FOR_DETECTING_TESTS:-$current_git_commit}" \
            --output-test-config "$test_conf_path" \
            affected
        extra_args+=( "--test_conf" "$test_conf_path" )
        unset test_conf_path
      fi
      set +u  # because extra_args can be empty
      if ! run_tests_on_spark "${extra_args[@]}"; then
        set -u
        EXIT_STATUS=1
        FAILURES+=$'Distributed tests on Spark (C++ and/or Java) failed\n'
        log "Some tests that were run on Spark failed"
      fi
      set -u
      unset extra_args
    else
      log "Neither C++ or Java tests are enabled, nothing to run on Spark."
    fi
  else
    # A single-node way of running tests (without Spark).

    if [[ $YB_BUILD_CPP == "1" ]]; then
      log "Run C++ tests in a non-distributed way"
      export GTEST_OUTPUT="xml:$TEST_LOG_DIR/" # Enable JUnit-compatible XML output.

      if ! spark_available; then
        log "Did not find Spark on the system, falling back to a ctest-based way of running tests"
        set +e
        time ctest -j$NUM_PARALLEL_TESTS ${EXTRA_TEST_FLAGS:-} \
            --output-log "$CTEST_FULL_OUTPUT_PATH" \
            --output-on-failure 2>&1 | tee "$CTEST_OUTPUT_PATH"
        if [[ $? -ne 0 ]]; then
          EXIT_STATUS=1
          FAILURES+=$'C++ tests failed\n'
        fi
        set -e
      fi
      log "Finished running C++ tests (see timing information above)"
    fi

    if [[ $YB_BUILD_JAVA == "1" ]]; then
      pushd "$YB_SRC_ROOT/java"
      log "Running Java tests in a non-distributed way"
      if ! time build_yb_java_code_with_retries "${java_build_cmd_line[@]}" verify 2>&1; then
        EXIT_STATUS=1
        FAILURES+=$'Java tests failed\n'
      fi
      log "Finished running Java tests (see timing information above)"
      popd
    fi
  fi
fi

# Finished running tests.
remove_latest_symlink

if [[ -n $FAILURES ]]; then
  heading "Failure summary"
  echo >&2 "$FAILURES"
fi

exit $EXIT_STATUS
