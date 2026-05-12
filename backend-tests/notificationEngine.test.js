const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const test = require("node:test");
const {
  cleanMerchantName,
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

test("old backfill transactions do not create single transaction alerts", () => {
  const transaction = tx({ transactionId: "old-openai", merchantName: "OpenAI", amount: 20, date: "2026-04-28" });
  const candidates = generateNotificationCandidates({
    transactions: [transaction],
    newTransactions: [transaction],
    now
  });

  assert.equal(candidates.some((candidate) => candidate.type === "single_transaction"), false);
});

test("bank payment descriptors are ignored", () => {
  const transaction = tx({
    transactionId: "bank-payment",
    merchantName: "CAPITAL ONE DES:MOBILE PMT ID:CA006A476182E22 INDN:Ranjit Singh CO ID:XXXXX44380 WEB",
    originalName: "CAPITAL ONE DES:MOBILE PMT ID:CA006A476182E22 INDN:Ranjit Singh CO ID:XXXXX44380 WEB",
    amount: 14.96,
    date: "2026-05-10"
  });
  const candidates = generateNotificationCandidates({
    transactions: [transaction],
    newTransactions: [transaction],
    now
  });

  assert.equal(candidates.length, 0);
});

test("bank descriptor merchant names are shortened for notification copy", () => {
  assert.equal(
    cleanMerchantName("DOORDASH DES:ACH TRANS ID:XXXXXXXXXX44001 INDN:BANK OF AMERICA, N.A. CO ID:XXXXX2202 WEB"),
    "Doordash"
  );
});

test("tax payments are not used for viral notifications", () => {
  const transaction = tx({
    transactionId: "irs",
    merchantName: "IRS TAX PAYMENT",
    originalName: "IRS TAX PAYMENT",
    amount: 1477,
    date: "2026-05-10",
    category: "other"
  });
  const candidates = generateNotificationCandidates({
    transactions: [transaction],
    newTransactions: [transaction],
    now
  });

  assert.equal(candidates.length, 0);
});
