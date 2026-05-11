const crypto = require("crypto");

function encryptionKey() {
  const secret = process.env.NOTIFICATION_ENCRYPTION_KEY;
  if (!secret) {
    if (process.env.ALLOW_INSECURE_DEV_STORAGE === "true") {
      return null;
    }
    throw new Error("NOTIFICATION_ENCRYPTION_KEY is required");
  }

  return crypto.createHash("sha256").update(secret).digest();
}

function encrypt(value) {
  const key = encryptionKey();
  if (!key) {
    return `plain:${value}`;
  }

  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();

  return [
    "v1",
    iv.toString("base64url"),
    tag.toString("base64url"),
    encrypted.toString("base64url")
  ].join(":");
}

function decrypt(value) {
  if (value.startsWith("plain:")) {
    return value.slice("plain:".length);
  }

  const [version, ivText, tagText, encryptedText] = value.split(":");
  if (version !== "v1") {
    throw new Error("Unsupported encrypted value");
  }

  const key = encryptionKey();
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(ivText, "base64url"));
  decipher.setAuthTag(Buffer.from(tagText, "base64url"));

  return Buffer.concat([
    decipher.update(Buffer.from(encryptedText, "base64url")),
    decipher.final()
  ]).toString("utf8");
}

module.exports = {
  decrypt,
  encrypt
};
