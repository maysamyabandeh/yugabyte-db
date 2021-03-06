// Copyright (c) YugaByte, Inc.
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

package com.yugabyte.sample.apps;

import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.List;

import com.yugabyte.sample.common.CmdLineOpts;
import org.apache.log4j.Logger;

import com.datastax.driver.core.BoundStatement;
import com.datastax.driver.core.ConsistencyLevel;
import com.datastax.driver.core.PreparedStatement;
import com.datastax.driver.core.ResultSet;
import com.datastax.driver.core.Row;
import com.yugabyte.sample.common.SimpleLoadGenerator.Key;

/**
 * This workload writes and reads some random string keys from a CQL server. By default, this app
 * inserts a million keys, and reads/updates them indefinitely.
 */
public class CassandraTransactionalKeyValue extends AppBase {
  private static final Logger LOG = Logger.getLogger(CassandraKeyValue.class);

  // Static initialization of this workload's config. These are good defaults for getting a decent
  // read dominated workload on a reasonably powered machine. Exact IOPS will of course vary
  // depending on the machine and what resources it has to spare.
  static {
    // Disable the read-write percentage.
    appConfig.readIOPSPercentage = -1;
    // Set the read and write threads to 1 each.
    appConfig.numReaderThreads = 24;
    appConfig.numWriterThreads = 2;
    // The number of keys to read.
    appConfig.numKeysToRead = -1;
    // The number of keys to write. This is the combined total number of inserts and updates.
    appConfig.numKeysToWrite = -1;
    // The number of unique keys to write. This determines the number of inserts (as opposed to
    // updates).
    appConfig.numUniqueKeysToWrite = NUM_UNIQUE_KEYS;
  }

  // The default table name to create and use for CRUD ops.
  private static final String DEFAULT_TABLE_NAME = CassandraKeyValue.class.getSimpleName();

  // The shared prepared select statement for fetching the data.
  private static volatile PreparedStatement preparedSelect;

  // The shared prepared statement for inserting into the table.
  private static volatile PreparedStatement preparedInsert;

  // Lock for initializing prepared statement objects.
  private static final Object prepareInitLock = new Object();

  public CassandraTransactionalKeyValue() {
    buffer = new byte[appConfig.valueSize];
  }

  /**
   * Drop the table created by this app.
   */
  @Override
  public void dropTable() {
    dropCassandraTable(getTableName());
  }

  @Override
  public List<String> getCreateTableStatements() {
    String create_stmt = String.format(
        "CREATE TABLE IF NOT EXISTS %s (k varchar, v blob, primary key (k)) " +
        "WITH transactions = { 'enabled' : true };", getTableName());
    return Arrays.asList(create_stmt);
  }

  protected PreparedStatement getPreparedSelect(String selectStmt, boolean localReads)  {
    if (preparedSelect == null) {
      synchronized (prepareInitLock) {
        if (preparedSelect == null) {
          // Create the prepared statement object.
          preparedSelect = getCassandraClient().prepare(selectStmt);
          if (localReads) {
            LOG.debug("Doing local reads");
            preparedSelect.setConsistencyLevel(ConsistencyLevel.ONE);
          } else {
            preparedSelect.setConsistencyLevel(ConsistencyLevel.QUORUM);
          }
        }
      }
    }
    return preparedSelect;
  }

  public String getTableName() {
    return appConfig.tableName != null ? appConfig.tableName : DEFAULT_TABLE_NAME;
  }

  private PreparedStatement getPreparedSelect()  {
    return getPreparedSelect(String.format("SELECT k, v, writetime(v) FROM %s WHERE k in :k;",
                                           getTableName()),
                             appConfig.localReads);
  }

  @Override
  public synchronized void resetClients() {
    synchronized (prepareInitLock) {
      preparedInsert = null;
      preparedSelect = null;
    }
    super.resetClients();
  }

  @Override
  public synchronized void destroyClients() {
    synchronized (prepareInitLock) {
      preparedInsert = null;
      preparedSelect = null;
    }
    super.destroyClients();
  }

  @Override
  public long doRead() {
    Key key = getSimpleLoadGenerator().getKeyToRead();
    if (key == null) {
      // There are no keys to read yet.
      return 0;
    }
    // Do the read from Cassandra.
    // Bind the select statement.
    BoundStatement select = getPreparedSelect().bind(Arrays.asList(key.asString() + "_1",
                                                                   key.asString() + "_2"));
    ResultSet rs = getCassandraClient().execute(select);
    List<Row> rows = rs.all();
    if (rows.size() != 2) {
      LOG.fatal("Read key: " + key.asString() + " expected 2 row in result, got " + rows.size());
      return 1;
    }
    if (appConfig.valueSize == 0) {
      ByteBuffer buf = rows.get(0).getBytes(1);
      String value1 = new String(buf.array());
      key.verify(value1);

      buf = rows.get(1).getBytes(1);
      String value2 = new String(buf.array());
      if (!value1.equals(value2)) {
       LOG.fatal("Value mismatch for key: " + key.toString() + ", " +
                 value1 + " vs " + value2);
      }
    } else {
      ByteBuffer value = rows.get(0).getBytes(1);
      byte[] bytes1 = new byte[value.capacity()];
      value.get(bytes1);
      verifyRandomValue(key, bytes1);

      value = rows.get(1).getBytes(1);
      byte[] bytes2 = new byte[value.capacity()];
      if (!bytes1.equals(bytes2)) {
        LOG.fatal("Value mismatch for key: " + key.toString());
      }
    }
    if (rows.get(0).getLong(2) != rows.get(1).getLong(2)) {
      LOG.fatal("Writetime mismatch for key: " + key.toString() + ", " +
                rows.get(0).getLong(2) + " vs " + rows.get(1).getLong(2));
    }

    LOG.debug("Read key: " + key.toString());
    return 1;
  }

  protected PreparedStatement getPreparedInsert(String insertStmt)  {
    if (preparedInsert == null) {
      synchronized (prepareInitLock) {
        if (preparedInsert == null) {
          // Create the prepared statement object.
          preparedInsert = getCassandraClient().prepare(insertStmt);
        }
      }
    }
    return preparedInsert;
  }

  protected PreparedStatement getPreparedInsert()  {
    return getPreparedInsert(String.format(
        "BEGIN TRANSACTION;" +
        "INSERT INTO %s (k, v) VALUES (:k1, :v);" +
        "INSERT INTO %s (k, v) VALUES (:k2, :v);" +
        "END TRANSACTION;",
        getTableName(),
        getTableName()));
  }

  @Override
  public long doWrite() {
    Key key = getSimpleLoadGenerator().getKeyToWrite();
    try {
      // Do the write to Cassandra.
      BoundStatement insert = null;
      if (appConfig.valueSize == 0) {
        String value = key.getValueStr();
        insert = getPreparedInsert()
                 .bind()
                 .setString("k1", key.asString() + "_1")
                 .setString("k2", key.asString() + "_2")
                 .setBytes("v", ByteBuffer.wrap(value.getBytes()));
      } else {
        byte[] value = getRandomValue(key);
        insert = getPreparedInsert()
                 .bind()
                 .setString("k1", key.asString() + "_1")
                 .setString("k2", key.asString() + "_2")
                 .setBytes("v", ByteBuffer.wrap(value));
      }
      ResultSet resultSet = getCassandraClient().execute(insert);
      LOG.debug("Wrote key: " + key.toString() + ", return code: " + resultSet.toString());
      getSimpleLoadGenerator().recordWriteSuccess(key);
      return 1;
    } catch (Exception e) {
      getSimpleLoadGenerator().recordWriteFailure(key);
      throw e;
    }
  }

  @Override
  public void appendMessage(StringBuilder sb) {
    super.appendMessage(sb);
    sb.append("maxWrittenKey: " + getSimpleLoadGenerator().getMaxWrittenKey() +  " | ");
    sb.append("maxGeneratedKey: " + getSimpleLoadGenerator().getMaxGeneratedKey() +  " | ");
  }

  public void appendParentMessage(StringBuilder sb) {
    super.appendMessage(sb);
  }

  @Override
  public List<String> getWorkloadDescription() {
    return Arrays.asList(
      "Sample key-value app with multi-row transaction built on Cassandra. The app writes",
      "out 1M unique string keys in pairs, with each pair of keys with the same string",
      "value written in a transaction. There are multiple readers and writers that update",
      "these keys and read them in pair indefinitely. Note that the number of reads and ",
      "writes to perform can be specified as a parameter.");
  }

  @Override
  public List<String> getExampleUsageOptions() {
    return Arrays.asList(
      "--num_unique_keys " + appConfig.numUniqueKeysToWrite,
      "--num_reads " + appConfig.numKeysToRead,
      "--num_writes " + appConfig.numKeysToWrite,
      "--value_size " + appConfig.valueSize,
      "--num_threads_read " + appConfig.numReaderThreads,
      "--num_threads_write " + appConfig.numWriterThreads);
  }
}
