// Copyright (c) YugaByte, Inc.
package org.yb.loadtester;

import com.datastax.driver.core.Row;
import com.yugabyte.sample.apps.CassandraSparkWordCount;
import com.yugabyte.sample.common.CmdLineOpts;
import org.junit.Ignore;
import org.junit.Test;
import org.yb.cql.BaseCQLTest;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.assertEquals;

import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.stream.Collectors;

public class TestCassandraSparkWordCount extends BaseCQLTest {

    private CassandraSparkWordCount app = new CassandraSparkWordCount();

    @Ignore
    public void testDefaultRun() throws Exception {
        // Set up config.
        String nodes = miniCluster.getCQLContactPoints().stream()
                .map(addr -> addr.getHostString() + ":" + addr.getPort())
                .collect(Collectors.joining(","));
        String[] args = {"--workload", "CassandraSparkWordCount", "--nodes", nodes};
        CmdLineOpts config = CmdLineOpts.createFromArgs(args);

        // Run the app.
        app.workloadInit(config, false);
        app.run();

        // Check row.
        Map<String, Integer> expectedValues = new HashMap<>();
        expectedValues.put("one", 1);
        expectedValues.put("two", 2);
        expectedValues.put("three", 3);
        expectedValues.put("four", 4);
        expectedValues.put("five", 5);
        expectedValues.put("six", 6);
        expectedValues.put("seven", 7);
        expectedValues.put("eight", 8);
        expectedValues.put("nine", 9);
        expectedValues.put("ten", 10);

        Iterator<Row> iterator = runSelect("SELECT * FROM ybdemo_keyspace.wordcounts");
        int rows_count = 0;
        while (iterator.hasNext()) {
            Row row = iterator.next();
            String word = row.getString("word");
            assertTrue(expectedValues.containsKey(word));
            assertEquals(expectedValues.get(word).intValue(), row.getInt("count"));
            rows_count++;
        }
        assertEquals(10, rows_count);
    }
}