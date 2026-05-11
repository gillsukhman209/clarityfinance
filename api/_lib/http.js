function sendJson(res, statusCode, body) {
  res.statusCode = statusCode;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.end(JSON.stringify(body));
}

function methodNotAllowed(res, allowed = "POST") {
  res.setHeader("allow", allowed);
  sendJson(res, 405, { ok: false, error: "method_not_allowed" });
}

function requireSharedSecret(req) {
  const expected = process.env.CLARITY_API_SECRET;
  if (!expected) {
    return true;
  }

  return req.headers["x-clarity-secret"] === expected;
}

async function readJson(req) {
  if (req.body && typeof req.body === "object") {
    return req.body;
  }

  if (typeof req.body === "string") {
    return JSON.parse(req.body || "{}");
  }

  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }

  const raw = Buffer.concat(chunks).toString("utf8");
  return raw ? JSON.parse(raw) : {};
}

module.exports = {
  methodNotAllowed,
  readJson,
  requireSharedSecret,
  sendJson
};
