// Quick test to verify MCP bridge file operations work
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MAILBOX_DIR = path.resolve(__dirname, "../shared/mailbox");

// Test creating a message
const testMsg = {
  id: "test-msg-001",
  from: "dev",
  to: "qa",
  type: "ready_for_qa",
  content: {
    summary: "Test message",
    files_changed: ["test.js"],
    test_instructions: "Run: node test.js",
  },
  timestamp: new Date().toISOString(),
  read: false,
};

const dir = `${MAILBOX_DIR}/to_qa`;
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(`${dir}/${testMsg.id}.json`, JSON.stringify(testMsg, null, 2));
console.log("✅ Created test message in to_qa/");

// Read it back
const files = fs.readdirSync(dir);
console.log(`✅ Found ${files.length} message(s) in to_qa/`);

// Clean up
fs.unlinkSync(`${dir}/${testMsg.id}.json`);
console.log("✅ Cleaned up test message");
console.log("\n🎉 MCP Bridge file operations working!");
