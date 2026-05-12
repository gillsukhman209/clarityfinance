const { methodNotAllowed, readJson, sendJson } = require("../_lib/http");
const { requireSupabaseUser } = require("../_lib/supabaseAuth");

const transactionKinds = [
  "subscription",
  "bill",
  "oneTimePurchase",
  "income",
  "transfer",
  "debtPayment",
  "fee",
  "refund",
  "unknown"
];

const categories = [
  "food",
  "shopping",
  "transport",
  "housing",
  "entertainment",
  "health",
  "utilities",
  "income",
  "transfer",
  "subscriptions",
  "other"
];

function responseSchema() {
  return {
    type: "object",
    additionalProperties: false,
    properties: {
      merchants: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            key: { type: "string" },
            display_name: { type: "string" },
            kind: { type: "string", enum: transactionKinds },
            category: { type: "string", enum: categories },
            confidence: { type: "number", minimum: 0, maximum: 1 },
            plain_english: { type: "string" }
          },
          required: ["key", "display_name", "kind", "category", "confidence", "plain_english"]
        }
      }
    },
    required: ["merchants"]
  };
}

function requestBody(merchants) {
  return {
    model: process.env.OPENAI_MODEL || "gpt-4.1-mini",
    instructions: `
You classify personal finance transaction merchants for a Gen Z spending app.
Be practical and conservative. Do not call one-off purchases subscriptions just because the merchant is famous.
Look at the individual transaction dates and amounts. Merchants like Apple, Google, Amazon, Meta, TikTok, and ad platforms can contain both real subscriptions and one-time purchases. A merchant should only be subscription/bill when the actual charge pattern is recurring, not just because the company sells subscriptions.
Tax payments, IRS, treasury, franchise tax, government fees, permit fees, filing fees, and estimated taxes are one-time payments unless the transaction dates show a monthly recurring payment plan.
A subscription means an ongoing paid service or membership. A bill means a recurring necessary payment like rent, utilities, insurance, loans, phone, internet, taxes, or credit card payments. Transfers and debt payments should not be counted as spending subscriptions.
Return short names and plain English that a normal person instantly understands.
`.trim(),
    input: [
      {
        role: "user",
        content: [
          {
            type: "input_text",
            text: `Classify these merchant spending groups. Return JSON that matches the schema exactly.\n${JSON.stringify(merchants)}`
          }
        ]
      }
    ],
    text: {
      format: {
        type: "json_schema",
        name: "clarity_merchant_classifications",
        strict: true,
        schema: responseSchema()
      }
    }
  };
}

function outputText(payload) {
  return (payload.output || [])
    .flatMap((item) => item.content || [])
    .map((content) => content.text)
    .find((text) => typeof text === "string" && text.length > 0);
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return methodNotAllowed(res);
  }

  try {
    await requireSupabaseUser(req);
    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      return sendJson(res, 500, { ok: false, error: "openai_api_key_missing" });
    }

    const body = await readJson(req);
    const merchants = Array.isArray(body.merchants) ? body.merchants.slice(0, 80) : [];
    if (merchants.length === 0) {
      return sendJson(res, 200, { ok: true, merchants: [] });
    }

    const response = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${apiKey}`
      },
      body: JSON.stringify(requestBody(merchants))
    });

    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      return sendJson(res, response.status, {
        ok: false,
        error: payload.error?.message || `OpenAI returned HTTP ${response.status}`
      });
    }

    const text = outputText(payload);
    if (!text) {
      return sendJson(res, 502, { ok: false, error: "openai_missing_output" });
    }

    const classifications = JSON.parse(text);
    return sendJson(res, 200, { ok: true, merchants: classifications.merchants || [] });
  } catch (error) {
    return sendJson(res, error.statusCode || 500, { ok: false, error: error.message });
  }
};
