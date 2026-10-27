/**
 * Cloudinary to Firebase Storage Safe, Idempotent, and Resumable Migration Tool
 *
 * Scans Firestore collections for Cloudinary asset references, downloads each asset,
 * uploads it to Firebase Storage under the appropriate path, verifies the uploaded file,
 * and updates Firestore references.
 *
 * Usage:
 *   cd functions
 *   node migrate_cloudinary.js [--dry-run] [--collection=name]
 */

const admin = require("firebase-admin");
const https = require("https");
const http = require("http");
const path = require("path");

if (!admin.apps.length) {
    admin.initializeApp();
}

const db = admin.firestore();
const storage = admin.storage();
const bucket = storage.bucket();

const isDryRun = process.argv.includes("--dry-run");

const report = {
    scanned: 0,
    migrated: 0,
    skipped: 0,
    failed: 0,
    unresolved: [],
    details: [],
};

function isCloudinaryUrl(url) {
    if (!url || typeof url !== "string") return false;
    const lower = url.toLowerCase();
    return lower.includes("cloudinary.com") || lower.includes("res.cloudinary");
}

function isFirebaseStorageUrl(url) {
    if (!url || typeof url !== "string") return false;
    const lower = url.toLowerCase();
    return lower.includes("firebasestorage.googleapis.com") ||
           lower.includes("firebasestorage.app") ||
           lower.includes("storage.googleapis.com");
}

function downloadAsset(url) {
    return new Promise((resolve, reject) => {
        const client = url.startsWith("https") ? https : http;
        const request = client.get(url, { timeout: 20000 }, (response) => {
            // Handle redirects
            if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
                return downloadAsset(response.headers.location).then(resolve).catch(reject);
            }
            if (response.statusCode !== 200) {
                return reject(new Error(`HTTP ${response.statusCode}: ${response.statusMessage}`));
            }
            const chunks = [];
            response.on("data", (chunk) => chunks.push(chunk));
            response.on("end", () => {
                const buffer = Buffer.concat(chunks);
                const contentType = response.headers["content-type"] || "application/octet-stream";
                resolve({ buffer, contentType });
            });
        });
        request.on("error", reject);
        request.on("timeout", () => {
            request.destroy();
            reject(new Error("Download timed out after 20 seconds"));
        });
    });
}

function resolveExtension(url, contentType) {
    const cleanUrl = url.split("?")[0].split("#")[0];
    const ext = path.extname(cleanUrl);
    if (ext && ext.length <= 5) return ext;
    if (contentType.includes("jpeg") || contentType.includes("jpg")) return ".jpg";
    if (contentType.includes("png")) return ".png";
    if (contentType.includes("webp")) return ".webp";
    if (contentType.includes("pdf")) return ".pdf";
    if (contentType.includes("mp4") || contentType.includes("m4a")) return ".m4a";
    return ".bin";
}

async function migrateFile({ sourceUrl, destinationPath, documentRef, fieldName }) {
    report.scanned++;

    if (!isCloudinaryUrl(sourceUrl)) {
        report.skipped++;
        return sourceUrl;
    }

    if (isFirebaseStorageUrl(sourceUrl)) {
        report.skipped++;
        return sourceUrl;
    }

    console.log(`\n[MIGRATE] Processing: ${sourceUrl}`);
    console.log(`         -> Target: ${destinationPath}`);

    if (isDryRun) {
        console.log("         [DRY RUN] Would download and upload to Firebase Storage");
        report.migrated++;
        return sourceUrl;
    }

    try {
        // Check if destination file already exists in bucket (idempotency)
        const file = bucket.file(destinationPath);
        const [exists] = await file.exists();

        let downloadUrl;
        if (exists) {
            console.log("         [IDEMPOTENT] File already exists in Firebase Storage, reusing.");
            const [signedUrl] = await file.getSignedUrl({
                action: "read",
                expires: "03-01-2500", // effectively permanent
            }).catch(() => [null]);
            downloadUrl = signedUrl || `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(destinationPath)}?alt=media`;
        } else {
            console.log("         Downloading asset from Cloudinary...");
            const { buffer, contentType } = await downloadAsset(sourceUrl);

            console.log(`         Uploading ${buffer.length} bytes to ${destinationPath}...`);
            await file.save(buffer, {
                metadata: {
                    contentType: contentType,
                    metadata: {
                        migratedFrom: sourceUrl,
                        migratedAt: new Date().toISOString(),
                    },
                },
                resumable: false,
            });

            // Verify existence
            const [verifiedExists] = await file.exists();
            if (!verifiedExists) {
                throw new Error("Verification failed: File was uploaded but does not exist in bucket");
            }

            downloadUrl = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(destinationPath)}?alt=media`;
            console.log(`         ✅ Upload verified successfully.`);
        }

        // Update Firestore document atomically
        if (documentRef && fieldName) {
            await documentRef.update({
                [fieldName]: downloadUrl,
                [`${fieldName}_migrated_from`]: sourceUrl,
                [`${fieldName}_migrated_at`]: admin.firestore.FieldValue.serverTimestamp(),
            });
            console.log(`         ✅ Firestore updated doc ${documentRef.id} [${fieldName}]`);
        }

        report.migrated++;
        report.details.push({
            status: "SUCCESS",
            source: sourceUrl,
            destination: destinationPath,
            doc: documentRef ? documentRef.path : null,
        });

        return downloadUrl;
    } catch (err) {
        console.error(`         ❌ Failed to migrate ${sourceUrl}: ${err.message}`);
        report.failed++;
        report.unresolved.push({
            source: sourceUrl,
            destination: destinationPath,
            doc: documentRef ? documentRef.path : null,
            error: err.message,
        });
        return null;
    }
}

async function migratePatients() {
    console.log("\n==================== Scanning Patients ====================");
    const snap = await db.collection("telemedicine_patient").get();
    for (const doc of snap.docs) {
        const data = doc.data();
        const imageUrl = data.image || data.profile_image || data.profileImage;
        if (isCloudinaryUrl(imageUrl)) {
            const ext = resolveExtension(imageUrl, "image/jpeg");
            const targetPath = `patients/${doc.id}/profile/profile_${Date.now()}${ext}`;
            const field = data.image ? "image" : (data.profile_image ? "profile_image" : "profileImage");
            await migrateFile({ sourceUrl: imageUrl, destinationPath: targetPath, documentRef: doc.ref, fieldName: field });
        }
    }
}

async function migrateDoctors() {
    console.log("\n==================== Scanning Doctors ====================");
    const snap = await db.collection("telemedicine_doctors").get();
    for (const doc of snap.docs) {
        const data = doc.data();
        const imageUrl = data.image || data.profile_image || data.profileImage;
        if (isCloudinaryUrl(imageUrl)) {
            const ext = resolveExtension(imageUrl, "image/jpeg");
            const targetPath = `doctors/${doc.id}/profile/profile_${Date.now()}${ext}`;
            const field = data.image ? "image" : (data.profile_image ? "profile_image" : "profileImage");
            await migrateFile({ sourceUrl: imageUrl, destinationPath: targetPath, documentRef: doc.ref, fieldName: field });
        }
    }
}

async function migratePayments() {
    console.log("\n==================== Scanning Payments ====================");
    const snap = await db.collection("payments").get();
    for (const doc of snap.docs) {
        const data = doc.data();
        const proofUrl = data.paymentProof || data.proofUrl || data.imageUrl || data.image;
        if (isCloudinaryUrl(proofUrl)) {
            const ext = resolveExtension(proofUrl, "image/jpeg");
            const patientUid = data.userId || data.patientId || "unknown_patient";
            const targetPath = `payment_proofs/${patientUid}/${doc.id}/proof${ext}`;
            const field = data.paymentProof ? "paymentProof" : (data.proofUrl ? "proofUrl" : (data.imageUrl ? "imageUrl" : "image"));
            await migrateFile({ sourceUrl: proofUrl, destinationPath: targetPath, documentRef: doc.ref, fieldName: field });
        }
    }
}

async function migrateAppointments() {
    console.log("\n==================== Scanning Appointments ====================");
    const snap = await db.collection("appointments").get();
    for (const doc of snap.docs) {
        const data = doc.data();
        const proofUrl = data.paymentProof || data.proofUrl;
        if (isCloudinaryUrl(proofUrl)) {
            const ext = resolveExtension(proofUrl, "image/jpeg");
            const targetPath = `appointments/${doc.id}/payment_proofs/proof${ext}`;
            const field = data.paymentProof ? "paymentProof" : "proofUrl";
            await migrateFile({ sourceUrl: proofUrl, destinationPath: targetPath, documentRef: doc.ref, fieldName: field });
        }
    }
}

async function migrateReports() {
    console.log("\n==================== Scanning Medical Reports ====================");
    const snap = await db.collection("reports").get();
    for (const doc of snap.docs) {
        const data = doc.data();
        const fileUrl = data.fileUrl;
        if (isCloudinaryUrl(fileUrl)) {
            const ext = resolveExtension(fileUrl, "application/pdf");
            const userId = data.userId || "shared";
            const targetPath = `reports/${userId}/${doc.id}_report${ext}`;
            await migrateFile({ sourceUrl: fileUrl, destinationPath: targetPath, documentRef: doc.ref, fieldName: "fileUrl" });
        }
    }
}

async function migrateChatMessages() {
    console.log("\n==================== Scanning Chat Messages ====================");
    const chatsSnap = await db.collection("chats").get();
    for (const chatDoc of chatsSnap.docs) {
        const messagesSnap = await chatDoc.ref.collection("messages").get();
        for (const msgDoc of messagesSnap.docs) {
            const data = msgDoc.data();
            const mediaUrl = data.mediaUrl;
            if (isCloudinaryUrl(mediaUrl)) {
                const msgType = data.messageType || "attachment";
                const ext = resolveExtension(mediaUrl, msgType === "audio" || msgType === "voice" ? "audio/mp4" : "image/jpeg");
                const folder = (msgType === "audio" || msgType === "voice") ? "chat_voice" : "chat_attachments";
                const targetPath = `${folder}/${chatDoc.id}/${msgDoc.id}${ext}`;
                await migrateFile({ sourceUrl: mediaUrl, destinationPath: targetPath, documentRef: msgDoc.ref, fieldName: "mediaUrl" });
            }
        }
    }
}

async function run() {
    console.log("===============================================================");
    console.log("  CLOUDINARY TO FIREBASE STORAGE RESUMABLE MIGRATION TOOL");
    console.log(`  Mode: ${isDryRun ? "DRY RUN (preview only)" : "LIVE MIGRATION"}`);
    console.log("===============================================================");

    const startTime = Date.now();

    try {
        await migratePatients();
        await migrateDoctors();
        await migratePayments();
        await migrateAppointments();
        await migrateReports();
        await migrateChatMessages();
    } catch (e) {
        console.error("Migration encountered a top-level error:", e);
    }

    const duration = ((Date.now() - startTime) / 1000).toFixed(1);

    console.log("\n===============================================================");
    console.log("  MIGRATION SUMMARY REPORT");
    console.log("===============================================================");
    console.log(`  Duration:             ${duration}s`);
    console.log(`  Total Assets Scanned: ${report.scanned}`);
    console.log(`  Successfully Migrated:${report.migrated}`);
    console.log(`  Skipped (Non-Cloud):  ${report.skipped}`);
    console.log(`  Failed Migrations:    ${report.failed}`);
    if (report.unresolved.length > 0) {
        console.log("\n  Unresolved Assets:");
        report.unresolved.forEach((item, idx) => {
            console.log(`    [${idx + 1}] Doc: ${item.doc}`);
            console.log(`        Source: ${item.source}`);
            console.log(`        Error:  ${item.error}`);
        });
    }
    console.log("===============================================================\n");
}

run().then(() => {
    process.exit(report.failed > 0 ? 1 : 0);
}).catch((err) => {
    console.error("Fatal error:", err);
    process.exit(1);
});
