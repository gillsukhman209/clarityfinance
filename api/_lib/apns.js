const http2 = require("http2");
const jwt = require("jsonwebtoken");

function apnsConfigured() {
  return Boolean(
    process.env.APNS_TEAM_ID &&
    process.env.APNS_KEY_ID &&
    process.env.APNS_PRIVATE_KEY &&
    process.env.APNS_BUNDLE_ID
  );
}

function makeAPNSToken() {
  const privateKey = process.env.APNS_PRIVATE_KEY.replace(/\\n/g, "\n");
  return jwt.sign({}, privateKey, {
    algorithm: "ES256",
    issuer: process.env.APNS_TEAM_ID,
    keyid: process.env.APNS_KEY_ID,
    expiresIn: "50m",
    header: {
      alg: "ES256",
      kid: process.env.APNS_KEY_ID
    }
  });
}

async function sendPush(device, notification) {
  if (process.env.APNS_DRY_RUN === "true" || !apnsConfigured()) {
    return {
      sent: false,
      dryRun: true,
      reason: apnsConfigured() ? "APNS_DRY_RUN=true" : "APNs env vars are missing"
    };
  }

  const environment = process.env.APNS_ENV === "production" ? "production" : "sandbox";
  const origin = environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  const token = makeAPNSToken();
  const payload = JSON.stringify({
    aps: {
      alert: {
        title: notification.title,
        body: notification.body
      },
      sound: "default"
    },
    clarity: {
      type: notification.type,
      merchant_key: notification.merchantKey,
      transaction_id: notification.transactionId
    }
  });

  return new Promise((resolve, reject) => {
    const client = http2.connect(origin);
    client.on("error", reject);

    const request = client.request({
      ":method": "POST",
      ":path": `/3/device/${device.apns_token}`,
      authorization: `bearer ${token}`,
      "apns-topic": process.env.APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json"
    });

    let response = "";
    let statusCode = 0;

    request.on("response", (headers) => {
      statusCode = Number(headers[":status"] || 0);
    });

    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      response += chunk;
    });
    request.on("end", () => {
      client.close();
      if (statusCode >= 200 && statusCode < 300) {
        resolve({ sent: true, dryRun: false, statusCode });
      } else {
        resolve({
          sent: false,
          dryRun: false,
          statusCode,
          reason: response || "APNs request failed"
        });
      }
    });
    request.on("error", (error) => {
      client.close();
      reject(error);
    });

    request.end(payload);
  });
}

module.exports = {
  sendPush
};
