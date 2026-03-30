import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import sharp from "sharp";

const TEMPLATE_PATH = "templates/template_main.png";
const MAX_TITLE = 120;
const MAX_SUBTITLE = 240;

function assertAdmin(request: {
  auth?: { uid: string; token?: Record<string, unknown> };
}): string {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }
  if (request.auth.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
  return request.auth.uid;
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function buildOverlaySvg(title: string, subtitle: string): string {
  const t = escapeXml(title);
  const st = escapeXml(subtitle);
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg width="1080" height="1080" xmlns="http://www.w3.org/2000/svg">
  <style>
    .title {
      fill: #ffffff;
      font-size: 56px;
      font-weight: 700;
      font-family: system-ui, -apple-system, "Segoe UI", Arial, sans-serif;
      text-anchor: middle;
    }
    .subtitle {
      fill: #f0f0f0;
      font-size: 36px;
      font-family: system-ui, -apple-system, "Segoe UI", Arial, sans-serif;
      text-anchor: middle;
    }
  </style>
  <text x="540" y="486" class="title">${t}</text>
  <text x="540" y="648" class="subtitle">${st}</text>
</svg>`;
}

function gcsPublicUrl(bucketName: string, objectPath: string): string {
  const enc = objectPath.split("/").map((p) => encodeURIComponent(p)).join("/");
  return `https://storage.googleapis.com/${bucketName}/${enc}`;
}

/**
 * Admin-only: composites title/subtitle onto Storage template, writes to generated_posts/, returns URL.
 */
export const generatePostImage = onCall(
  {
    region: "us-central1",
    memory: "1GiB",
    timeoutSeconds: 120,
  },
  async (request) => {
    assertAdmin(request);
    const title =
      typeof request.data?.title === "string" ? request.data.title.trim() : "";
    const subtitle =
      typeof request.data?.subtitle === "string"
        ? request.data.subtitle.trim()
        : "";
    if (!title) {
      throw new HttpsError("invalid-argument", "title is required");
    }
    if (!subtitle) {
      throw new HttpsError("invalid-argument", "subtitle is required");
    }
    if (title.length > MAX_TITLE || subtitle.length > MAX_SUBTITLE) {
      throw new HttpsError(
        "invalid-argument",
        `title max ${MAX_TITLE} chars, subtitle max ${MAX_SUBTITLE}`
      );
    }

    const bucket = admin.storage().bucket();

    let templateBuffer: Buffer;
    try {
      [templateBuffer] = await bucket.file(TEMPLATE_PATH).download();
    } catch (e: unknown) {
      console.error("generatePostImage: template download failed", e);
      throw new HttpsError(
        "failed-precondition",
        "Upload templates/template_main.png to Firebase Storage (1080×1080 PNG)."
      );
    }

    const svg = buildOverlaySvg(title, subtitle);
    let pngBuffer: Buffer;
    try {
      pngBuffer = await sharp(templateBuffer)
        .composite([
          {
            input: Buffer.from(svg, "utf-8"),
            top: 0,
            left: 0,
          },
        ])
        .png()
        .toBuffer();
    } catch (e: unknown) {
      console.error("generatePostImage: sharp failed", e);
      throw new HttpsError("internal", "Image generation failed");
    }

    const destPath = `generated_posts/post_${Date.now()}.png`;
    const file = bucket.file(destPath);
    await file.save(pngBuffer, {
      metadata: {
        contentType: "image/png",
        cacheControl: "public, max-age=31536000",
      },
      resumable: false,
    });

    let imageUrl: string;
    try {
      await file.makePublic();
      imageUrl = gcsPublicUrl(bucket.name, destPath);
    } catch (e: unknown) {
      console.warn("generatePostImage: makePublic failed, using signed URL", e);
      const [signed] = await file.getSignedUrl({
        action: "read",
        expires: Date.now() + 10 * 365 * 24 * 60 * 60 * 1000,
      });
      imageUrl = signed;
    }

    return { success: true, imageUrl };
  }
);
