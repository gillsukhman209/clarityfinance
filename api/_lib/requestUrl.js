function validHTTPSURL(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) {
    return null;
  }

  try {
    const url = new URL(trimmed);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function webhookURLForRequest(req) {
  const configuredURL = validHTTPSURL(process.env.PLAID_WEBHOOK_URL);
  if (configuredURL) {
    return configuredURL;
  }

  const host = String(req.headers["x-forwarded-host"] || req.headers.host || "").split(",")[0].trim();
  if (!host) {
    return null;
  }

  return `https://${host}/api/plaid/webhook`;
}

module.exports = {
  validHTTPSURL,
  webhookURLForRequest
};
