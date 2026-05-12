function dollars(value) {
  return `$${Math.round(value).toLocaleString("en-US")}`;
}

function merchantKey(name) {
  return String(name || "Unknown")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function cleanMerchantName(name) {
  const cleaned = String(name || "Unknown")
    .replace(/\s+/g, " ")
    .replace(/\b(des|indn|co id|ach trans id|mobile pmt id):.*$/i, "")
    .replace(/\b\d{4,}\b/g, "")
    .trim();
  return titleCaseMerchant(cleaned || "Unknown");
}

function titleCaseMerchant(name) {
  return String(name || "Unknown")
    .split(" ")
    .filter(Boolean)
    .map((part) => {
      if (/^[A-Z]{2,}$/.test(part) && part.length <= 5) {
        return part;
      }
      if (/^[A-Z]{2,}$/.test(part)) {
        return part.charAt(0) + part.slice(1).toLowerCase();
      }
      return part.charAt(0).toUpperCase() + part.slice(1);
    })
    .join(" ");
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function addDays(date, days) {
  const next = new Date(date);
  next.setDate(next.getDate() + days);
  return next;
}

function parseTransactionDate(value) {
  if (value instanceof Date) {
    return value;
  }

  const text = String(value || "");
  const match = text.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (match) {
    return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  }

  return new Date(text);
}

function dayLabel(transactionDate, now) {
  const txDay = startOfDay(transactionDate);
  const today = startOfDay(now);
  const yesterday = addDays(today, -1);

  if (txDay.getTime() === today.getTime()) {
    return "today";
  }
  if (txDay.getTime() === yesterday.getTime()) {
    return "yesterday";
  }
  return `on ${transactionDate.toLocaleDateString("en-US", { month: "short", day: "numeric" })}`;
}

function isExpense(transaction) {
  const category = String(transaction.category || "").toLowerCase();
  const name = `${transaction.merchantName || ""} ${transaction.originalName || ""}`.toLowerCase();

  if (Number(transaction.amount) <= 0) {
    return false;
  }

  if (/(income|transfer|refund|payroll|deposit)/.test(category)) {
    return false;
  }

  if (/(payment thank you|credit card payment|autopay payment|online payment|transfer|mobile pmt|ach trans|des:ach|co id:|indn:|interest charged)/.test(name)) {
    return false;
  }

  if (/(^|\b)(irs|internal revenue|treasury|franchise tax|estimated tax|tax payment|state tax|ftb)(\b|$)/.test(name)) {
    return false;
  }

  return true;
}

function isFreshForNotification(transaction, now) {
  const date = parseTransactionDate(transaction.date);
  if (Number.isNaN(date.getTime())) {
    return false;
  }

  const todayEnd = addDays(startOfDay(now), 1);
  const recentStart = addDays(startOfDay(now), -2);
  return date >= recentStart && date < todayEnd;
}

function roastForMerchant(name, tone) {
  const key = merchantKey(name);
  const brutal = tone === "brutal";
  const clean = tone === "clean";

  if (/starbucks|dutch bros|coffee/.test(key)) {
    if (clean) return "Coffee is becoming a weekly pattern.";
    return brutal ? "That coffee budget is acting employed." : "At this point it is basically a subscription.";
  }
  if (/target/.test(key)) {
    if (clean) return "This merchant is driving the week.";
    return brutal ? "You went in for one thing. Sure." : "Target did what Target does.";
  }
  if (/doordash|uber eats|grubhub/.test(key)) {
    if (clean) return "Delivery is adding up this week.";
    return brutal ? "The stove is still available." : "Convenience had a week.";
  }
  if (/amazon/.test(key)) {
    if (clean) return "Online shopping is adding up.";
    return brutal ? "The packages are winning." : "A familiar plot twist.";
  }
  if (/apple/.test(key)) {
    if (clean) return "Apple charges are stacking up.";
    return brutal ? "Apple found the card again." : "Apple had a little moment.";
  }

  if (clean) return "This is worth reviewing.";
  return brutal ? "That is not nothing." : "Worth noticing.";
}

function copyForSingleTransaction(transaction, now, settings) {
  const merchant = cleanMerchantName(transaction.merchantName || transaction.originalName);
  if (settings.privacy === "private") {
    return {
      title: "Spending update",
      body: "Your spending update is ready."
    };
  }

  return {
    title: "New spending",
    body: `You spent ${dollars(Number(transaction.amount))} at ${merchant} ${dayLabel(parseTransactionDate(transaction.date), now)}.`
  };
}

function makeCandidate(type, fields) {
  return {
    id: `${type}:${fields.merchantKey || "all"}:${fields.transactionId || "none"}`,
    type,
    score: fields.score,
    merchantKey: fields.merchantKey || null,
    transactionId: fields.transactionId || null,
    title: fields.title,
    body: fields.body,
    metadata: fields.metadata || {}
  };
}

function totalsBetween(transactions, start, end) {
  return transactions
    .filter((transaction) => {
      const date = parseTransactionDate(transaction.date);
      return date >= start && date < end;
    })
    .reduce((total, transaction) => total + Number(transaction.amount || 0), 0);
}

function samePointLastMonth(now) {
  const startThisMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  const startLastMonth = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const dayOffset = Math.max(0, startOfDay(now).getDate() - 1);
  const endLastMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  const samePoint = addDays(startLastMonth, dayOffset + 1);
  return {
    start: startLastMonth,
    end: samePoint < endLastMonth ? samePoint : endLastMonth,
    currentStart: startThisMonth,
    currentEnd: addDays(startOfDay(now), 1)
  };
}

function generateNotificationCandidates({
  transactions,
  newTransactions = [],
  now = new Date(),
  settings = {}
}) {
  const mergedSettings = {
    tone: settings.tone || "funny",
    privacy: settings.privacy || "merchant_amount"
  };
  const expenses = transactions.filter(isExpense);
  const newExpenses = newTransactions
    .filter(isExpense)
    .filter((transaction) => isFreshForNotification(transaction, now));
  const candidates = [];

  for (const transaction of newExpenses) {
    const amount = Number(transaction.amount || 0);
    if (amount < 10) {
      continue;
    }

    const copy = copyForSingleTransaction(transaction, now, mergedSettings);
    const name = cleanMerchantName(transaction.merchantName || transaction.originalName);
    candidates.push(makeCandidate("single_transaction", {
      score: Math.min(75, 30 + amount / 4),
      merchantKey: merchantKey(name),
      transactionId: transaction.transactionId || transaction.id,
      title: copy.title,
      body: copy.body,
      metadata: { amount, merchantName: name }
    }));
  }

  const lastSevenStart = addDays(startOfDay(now), -6);
  const tomorrow = addDays(startOfDay(now), 1);
  const previousSevenStart = addDays(startOfDay(now), -13);
  const lastSeven = expenses.filter((transaction) => parseTransactionDate(transaction.date) >= lastSevenStart && parseTransactionDate(transaction.date) < tomorrow);

  const merchantGroups = new Map();
  for (const transaction of lastSeven) {
    const name = cleanMerchantName(transaction.merchantName || transaction.originalName);
    const key = merchantKey(name);
    const existing = merchantGroups.get(key) || { key, name, total: 0, count: 0 };
    existing.total += Number(transaction.amount || 0);
    existing.count += 1;
    merchantGroups.set(key, existing);
  }

  for (const group of merchantGroups.values()) {
    if (group.total < 40 && group.count < 3) {
      continue;
    }

    const title = `${group.name} check`;
    const body = mergedSettings.privacy === "private"
      ? "Your spending update is ready."
      : `You spent ${dollars(group.total)} at ${group.name} this week. ${roastForMerchant(group.name, mergedSettings.tone)}`;

    candidates.push(makeCandidate("merchant_roast", {
      score: 85 + Math.min(40, group.total / 10) + group.count,
      merchantKey: group.key,
      title,
      body,
      metadata: { total: group.total, count: group.count, merchantName: group.name }
    }));
  }

  const lastSevenTotal = totalsBetween(expenses, lastSevenStart, tomorrow);
  const previousSevenTotal = totalsBetween(expenses, previousSevenStart, lastSevenStart);
  if (lastSevenTotal >= 50 && previousSevenTotal > 0) {
    const delta = lastSevenTotal - previousSevenTotal;
    const percent = delta / previousSevenTotal;
    if (delta >= 50 || percent >= 0.2) {
      candidates.push(makeCandidate("weekly_trend", {
        score: 78 + Math.min(30, percent * 30),
        title: "Spending trend",
        body: mergedSettings.privacy === "private"
          ? "Your weekly spending trend is ready."
          : `Your last 7 days are up ${Math.round(percent * 100)}%. Something changed.`,
        metadata: { current: lastSevenTotal, previous: previousSevenTotal, percent }
      }));
    }
  }

  const month = samePointLastMonth(now);
  const currentMonthTotal = totalsBetween(expenses, month.currentStart, month.currentEnd);
  const samePointLastMonthTotal = totalsBetween(expenses, month.start, month.end);
  if (currentMonthTotal >= 100 && samePointLastMonthTotal > 0) {
    const delta = currentMonthTotal - samePointLastMonthTotal;
    const percent = delta / samePointLastMonthTotal;
    if (percent >= 0.4) {
      candidates.push(makeCandidate("monthly_pace", {
        score: 68 + Math.min(25, percent * 20),
        title: "Monthly pace",
        body: mergedSettings.privacy === "private"
          ? "Your monthly spending pace is ready."
          : `You are spending ${Math.round(percent * 100)}% more than this point last month.`,
        metadata: { current: currentMonthTotal, previous: samePointLastMonthTotal, percent }
      }));
    }
  }

  return candidates.sort((lhs, rhs) => rhs.score - lhs.score);
}

function generateExpensiveDayCandidate({ transactions, now = new Date(), settings = {} }) {
  const expenses = transactions.filter(isExpense);
  const weekday = now.getDay();
  const totals = Array.from({ length: 7 }, (_, day) => ({ day, total: 0, count: 0 }));

  for (const transaction of expenses) {
    const date = parseTransactionDate(transaction.date);
    totals[date.getDay()].total += Number(transaction.amount || 0);
    totals[date.getDay()].count += 1;
  }

  const today = totals[weekday];
  const top = totals.reduce((best, item) => item.total > best.total ? item : best, totals[0]);
  if (top.day !== weekday || today.total < 100 || today.count < 2) {
    return null;
  }

  const dayName = now.toLocaleDateString("en-US", { weekday: "long" });
  return makeCandidate("expensive_day", {
    score: 72,
    title: "Careful today",
    body: settings.privacy === "private"
      ? "Today is one of your expensive days."
      : `${dayName} is usually your most expensive day. Move carefully.`,
    metadata: { weekday, total: today.total, count: today.count }
  });
}

module.exports = {
  cleanMerchantName,
  generateExpensiveDayCandidate,
  generateNotificationCandidates,
  isExpense,
  merchantKey
};
