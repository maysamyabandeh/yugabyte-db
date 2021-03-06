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
package org.yb.cql;

import java.util.*;

import org.junit.Test;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertEquals;

import com.datastax.driver.core.Row;
import com.datastax.driver.core.PreparedStatement;

public class TestTransaction extends BaseCQLTest {

  private void createTable(String name, String columns, boolean transactional) {
    session.execute(String.format("create table %s (%s) with transactions = { 'enabled' : %b };",
                                  name, columns, transactional));
  }

  private void createTables() throws Exception {
    createTable("test_txn1", "k int primary key, c1 int, c2 text", true);
    createTable("test_txn2", "k int primary key, c1 int, c2 text", true);
    createTable("test_txn3", "k int primary key, c1 int, c2 text", true);
  }

  @Test
  public void testInsertMultipleTables() throws Exception {

    createTables();

    // Insert into multiple tables and ensure all rows are written with same writetime.
    session.execute("begin transaction;" +
                    "insert into test_txn1 (k, c1, c2) values (?, ?, ?);" +
                    "insert into test_txn2 (k, c1, c2) values (?, ?, ?);" +
                    "insert into test_txn3 (k, c1, c2) values (?, ?, ?);" +
                    "end transaction;",
                    Integer.valueOf(1), Integer.valueOf(1), "v1",
                    Integer.valueOf(2), Integer.valueOf(2), "v2",
                    Integer.valueOf(3), Integer.valueOf(3), "v3");

    Vector<Row> rows = new Vector<Row>();
    for (int i = 1; i <= 3; i++) {
      rows.add(session.execute(String.format("select c1, c2, writetime(c1), writetime(c2) " +
                                             "from test_txn%d where k = ?;", i),
                               Integer.valueOf(i)).one());
      assertNotNull(rows.get(i - 1));
      assertEquals(i, rows.get(i - 1).getInt("c1"));
      assertEquals("v" + i, rows.get(i - 1).getString("c2"));
    }

    // Verify writetimes are same.
    assertEquals(rows.get(0).getLong("writetime(c1)"), rows.get(1).getLong("writetime(c1)"));
    assertEquals(rows.get(0).getLong("writetime(c1)"), rows.get(2).getLong("writetime(c1)"));
    assertEquals(rows.get(0).getLong("writetime(c2)"), rows.get(1).getLong("writetime(c2)"));
    assertEquals(rows.get(0).getLong("writetime(c2)"), rows.get(2).getLong("writetime(c2)"));
  }

  @Test
  public void testInsertUpdateSameTable() throws Exception {

    createTables();

    // Insert multiple keys into same table and ensure all rows are written with same writetime.
    session.execute("start transaction;" +
                    "insert into test_txn1 (k, c1, c2) values (?, ?, ?);" +
                    "insert into test_txn1 (k, c1, c2) values (?, ?, ?);" +
                    "update test_txn1 set c1 = ?, c2 = ? where k = ?;" +
                    "commit;",
                    Integer.valueOf(1), Integer.valueOf(1), "v1",
                    Integer.valueOf(2), Integer.valueOf(2), "v2",
                    Integer.valueOf(3), "v3", Integer.valueOf(3));

    Vector<Row> rows = new Vector<Row>();
    HashSet<String> values = new HashSet<String>();
    for (Row row : session.execute("select c1, c2, writetime(c1), writetime(c2) " +
                                   "from test_txn1 where k in ?;",
                                   Arrays.asList(Integer.valueOf(1),
                                                 Integer.valueOf(2),
                                                 Integer.valueOf(3)))) {
      rows.add(row);
      values.add(row.getInt("c1") + "," + row.getString("c2"));
    }
    assertEquals(3, rows.size());
    assertEquals(new HashSet<String>(Arrays.asList("1,v1", "2,v2", "3,v3")), values);

    // Verify writetimes are same.
    assertEquals(rows.get(0).getLong("writetime(c1)"), rows.get(1).getLong("writetime(c1)"));
    assertEquals(rows.get(0).getLong("writetime(c1)"), rows.get(2).getLong("writetime(c1)"));
    assertEquals(rows.get(0).getLong("writetime(c2)"), rows.get(1).getLong("writetime(c2)"));
    assertEquals(rows.get(0).getLong("writetime(c2)"), rows.get(2).getLong("writetime(c2)"));
  }

  @Test
  public void testMixDML() throws Exception {

    createTables();

    // Test non-transactional writes to transaction-enabled table.
    for (int i = 1; i <= 2; i++) {
      session.execute("insert into test_txn1 (k, c1, c2) values (?, ?, ?);",
                      Integer.valueOf(i), Integer.valueOf(i), "v" + i);
    }
    assertQuery("select * from test_txn1;",
                new HashSet<String>(Arrays.asList("Row[1, 1, v1]", "Row[2, 2, v2]")));

    // Test a mix of insert/update/delete in the same transaction.
    session.execute("begin transaction;" +
                    "insert into test_txn1 (k, c1, c2) values (?, ?, ?);" +
                    "update test_txn1 set c1 = 0, c2 = 'v0' where k = ?;" +
                    "delete from test_txn1 where k = ?;" +
                    "end transaction;",
                    Integer.valueOf(3), Integer.valueOf(3), "v3",
                    Integer.valueOf(2),
                    Integer.valueOf(1));

    // Verify the rows.
    Vector<Row> rows = new Vector<Row>();
    HashSet<String> values = new HashSet<String>();
    for (Row row : session.execute("select k, c1, c2, writetime(c1), writetime(c2) " +
                                   "from test_txn1 where k in ?;",
                                   Arrays.asList(Integer.valueOf(1),
                                                 Integer.valueOf(2),
                                                 Integer.valueOf(3)))) {
      rows.add(row);
      values.add(row.getInt("k") + "," + row.getInt("c1") + "," + row.getString("c2"));
    }
    assertEquals(2, rows.size());
    assertEquals(new HashSet<String>(Arrays.asList("2,0,v0", "3,3,v3")), values);

    // Verify writetimes are same.
    assertEquals(rows.get(0).getLong("writetime(c1)"), rows.get(1).getLong("writetime(c1)"));
    assertEquals(rows.get(0).getLong("writetime(c2)"), rows.get(1).getLong("writetime(c2)"));
  }

  @Test
  public void testPrepareStatement() throws Exception {

    createTable("test_hash", "h1 int, h2 int, r int, c text, primary key ((h1, h2), r)", true);

    // Prepare a transaction statement. Verify the hash key of the whole statement is the first
    // insert statement that has the full hash key specified (third insert).
    PreparedStatement stmt =
        session.prepare("begin transaction;" +
                        "insert into test_hash (h1, h2, r, c) values (1, 1, ?, ?);" +
                        "insert into test_hash (h1, h2, r, c) values (?, 2, ?, ?);" +
                        "insert into test_hash (h1, h2, r, c) values (?, ?, ?, ?);" +
                        "end transaction;");
    int hashIndexes[] = stmt.getRoutingKeyIndexes();
    assertEquals(2, hashIndexes.length);
    assertEquals(5, hashIndexes[0]);
    assertEquals(6, hashIndexes[1]);

    session.execute(stmt.bind(Integer.valueOf(1), "v1",
                              Integer.valueOf(2), Integer.valueOf(2), "v2",
                              Integer.valueOf(3), Integer.valueOf(3), Integer.valueOf(3), "v3"));

    // Verify the rows.
    Vector<Row> rows = new Vector<Row>();
    HashSet<String> values = new HashSet<String>();
    for (Row row : session.execute("select h1, h2, r, c, writetime(c) from test_hash;")) {
      rows.add(row);
      values.add(row.getInt("h1")+","+row.getInt("h2")+","+row.getInt("r")+","+row.getString("c"));
    }
    assertEquals(3, rows.size());
    assertEquals(new HashSet<String>(Arrays.asList("1,1,1,v1",
                                                   "2,2,2,v2",
                                                   "3,3,3,v3")), values);
    // Verify writetimes are same.
    assertEquals(rows.get(0).getLong("writetime(c)"), rows.get(1).getLong("writetime(c)"));
    assertEquals(rows.get(0).getLong("writetime(c)"), rows.get(2).getLong("writetime(c)"));
  }

  @Test
  public void testInvalidStatements() throws Exception {
    createTables();

    // Missing "begin transaction"
    runInvalidStmt("insert into test_txn1 (k, c1, c2) values (?, ?, ?);" +
                   "insert into test_txn2 (k, c1, c2) values (?, ?, ?);" +
                   "commit;");

    // Missing "end transaction"
    runInvalidStmt("begin transaction;" +
                   "insert into test_txn1 (k, c1, c2) values (?, ?, ?);" +
                   "insert into test_txn2 (k, c1, c2) values (?, ?, ?);");

    // Missing "begin / end transaction"
    runInvalidStmt("insert into test_txn1 (k, c1, c2) values (?, ?, ?);" +
                   "insert into test_txn2 (k, c1, c2) values (?, ?, ?);");

    // Writing to non-transactional table
    createTable("test_non_txn", "k int primary key, c1 int, c2 text", false);
    runInvalidStmt("begin transaction;" +
                   "insert into test_txn1 (k, c1, c2) values (?, ?, ?);" +
                   "insert into test_non_txn (k, c1, c2) values (?, ?, ?);" +
                   "end transaction;");

    // Conditional DML not supported yet
    runInvalidStmt("begin transaction;" +
                   "insert into test_txn1 (k, c1, c2) values (?, ?, ?) if not exists;" +
                   "end transaction;");

    // Multiple writes to the same row are not allowed
    runInvalidStmt("begin transaction;" +
                   "insert into test_txn1 (k, c1, c2) values (1, 1, 'v1');" +
                   "delete from test_txn1 where k = 1;" +
                   "end transaction;");

    // Multiple writes to the same static row are not allowed
    createTable("test_static", "h int, r int, s int static, c int, primary key ((h), r)", true);
    runInvalidStmt("begin transaction;" +
                   "insert into test_static (h, s) values (1, 1);" +
                   "insert into test_static (h, r, s, c) values (1, 2, 3, 4);" +
                   "end transaction;");
  }
}
