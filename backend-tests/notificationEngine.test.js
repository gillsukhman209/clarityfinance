const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const test = require("node:test");
const {
  generateNotificationCandidates,
  isExpense
} = require("../api/_lib/notificationEngine");

const now = new Date("2026-05-10T19:00:00Z");

function tx(overrides) {
  return {
    transactionId: overrides.transactionId || crypto.randomUUID(),
    merchantName: overrides.merchantName || "Starbucks",
    originalName: overrides.originalName || overrides.merchantName || "Starbucks",
    amount: overrides.amount ?? 12,
    date: overrides.date || "2026-05-10",
    category: overrides.category || "food_and_drink",
    pending: false
  };
}

test("Starbucks today creates today copy", () => {
  const transaction = tx({ transactionId: "today", date: "2026-05-10", amount: 10 });
  const candidates = generateNotificationCandidates({
    transactions: [transaction],
    newTransactions: [transaction],
    now
  });

  assert.match(candidates[0].body, /Starbucks/);
  assert.match(candidates[0].body, /today/);
});

test("yesterday transaction creates yesterday copy", () => {
  const transaction = tx({ transactionId: "yesterday", date: "2026-05-09", amount: 10 });
  const candidates = generateNotificationCandidates({
    transactions: [transaction],
    newTransactions: [transaction],
    now
  });

  assert.match(candidates[0].body, /yesterday/);
});

test("weekly spend increase creates trend alert", () => {
  const transactions = [
    tx({ transactionId: "a", merchantName: "Target", amount: 90, date: "2026-05-10" }),
    tx({ transactionId: "b", merchantName: "Uber Eats", amount: 90, date: "2026-05-09" }),
    tx({ transactionId: "c", merchantName: "Groceries", amount: 20, date: "2026-04-30" })
  ];
  const candidates = generateNotificationCandidates({ transactions, now });

  assert.ok(candidates.some((candidate) => candidate.type === "weekly_trend"));
});

test("income transfers and refunds are ignored", () => {
  assert.equal(isExpense(tx({ amount: -100, category: "income" })), false);
  assert.equal(isExpense(tx({ amount: 100, category: "transfer" })), false);
  assert.equal(isExpense(tx({ amount: 100, category: "refund" })), false);
  assert.equal(isExpense(tx({ amount: 100, originalName: "Credit Card Payment Thank You" })), false);
});

test("small single transactions are ignored unless part of a merchant trend", () => {
  const transaction = tx({ transactionId: "small", amount: 6, date: "2026-05-10" });
  const candidates = generateNotificationCandidates({
    transactions: [transaction],
    newTransactions: [transaction],
    now
  });

  assert.equal(candidates.some((candidate) => candidate.type === "single_transaction"), false);
});
