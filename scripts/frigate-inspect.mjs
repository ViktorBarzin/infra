#!/usr/bin/env node
// Frigate Classification Page Inspector
// Phase 1: Fetch API data via HTTP to understand the data model
// Phase 2: Fetch the classification page HTML and parse its DOM structure
// No browser needed — uses plain HTTP requests.

import { spawn } from "child_process";
import http from "http";

const KUBE_CONFIG = `${process.cwd()}/config`;
const LOCAL_PORT = 15000;
const FRIGATE_NS = "frigate";
const FRIGATE_SVC = "svc/frigate";
const FRIGATE_PORT = 80;
const BASE_URL = `http://localhost:${LOCAL_PORT}`;

async function startPortForward() {
  console.log(
    `[port-forward] Starting: kubectl port-forward ${FRIGATE_SVC} ${LOCAL_PORT}:${FRIGATE_PORT} -n ${FRIGATE_NS}`,
  );
  const proc = spawn(
    "kubectl",
    [
      "--kubeconfig",
      KUBE_CONFIG,
      "port-forward",
      FRIGATE_SVC,
      `${LOCAL_PORT}:${FRIGATE_PORT}`,
      "-n",
      FRIGATE_NS,
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );

  await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("Port-forward timed out")),
      15000,
    );
    proc.stdout.on("data", (data) => {
      if (data.toString().includes("Forwarding from")) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.stderr.on("data", (data) => {
      console.error(`[port-forward stderr] ${data.toString().trim()}`);
    });
    proc.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    proc.on("exit", (code) => {
      if (code !== null && code !== 0) {
        clearTimeout(timer);
        reject(new Error(`port-forward exited with code ${code}`));
      }
    });
  });

  console.log("[port-forward] Ready");
  return proc;
}

function httpGet(path) {
  return new Promise((resolve, reject) => {
    const url = `${BASE_URL}${path}`;
    http.get(url, (res) => {
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () =>
        resolve({ status: res.statusCode, body, headers: res.headers }),
      );
    }).on("error", (err) => reject(err));
  });
}

async function main() {
  let portForwardProc = null;

  try {
    portForwardProc = await startPortForward();

    // ================================================================
    // API INSPECTION
    // ================================================================
    console.log("\n" + "=".repeat(80));
    console.log("API INSPECTION");
    console.log("=".repeat(80));

    // Get config to find model names
    const configResp = await httpGet("/api/config");
    let modelNames = [];
    if (configResp.status === 200) {
      try {
        const config = JSON.parse(configResp.body);
        // Custom classification models are under config.classification.custom
        const classificationModels = config.classification?.custom || {};
        modelNames = Object.keys(classificationModels);
        console.log(
          `\n[API] /api/config - Classification models: ${JSON.stringify(modelNames)}`,
        );
        console.log(
          `[API] Classification config:\n${JSON.stringify(config.classification, null, 2)}`,
        );
      } catch (e) {
        console.log(`[API] /api/config - Failed to parse: ${e.message}`);
        console.log(
          `[API] Raw (first 500): ${configResp.body.slice(0, 500)}`,
        );
      }
    } else {
      console.log(`[API] /api/config - HTTP ${configResp.status}`);
    }

    for (const model of modelNames) {
      console.log(`\n--- Model: ${model} ---`);
      const encodedModel = encodeURIComponent(model);

      // Dataset endpoint
      const datasetResp = await httpGet(
        `/api/classification/${encodedModel}/dataset`,
      );
      if (datasetResp.status === 200) {
        try {
          const dataset = JSON.parse(datasetResp.body);
          // Dataset response: { categories: { catName: [files...] }, training_metadata: {...} }
          const cats = dataset.categories || dataset;
          const categories = Object.keys(cats);
          console.log(`[API] /api/classification/${model}/dataset`);
          console.log(`  Categories: ${JSON.stringify(categories)}`);
          for (const cat of categories) {
            const items = Array.isArray(cats[cat]) ? cats[cat] : [];
            console.log(
              `  "${cat}": ${items.length} items, first 3: ${JSON.stringify(items.slice(0, 3))}`,
            );
          }
          if (dataset.training_metadata) {
            console.log(`  Training metadata: ${JSON.stringify(dataset.training_metadata, null, 2)}`);
          }
        } catch (e) {
          console.log(`  Failed to parse dataset: ${e.message}`);
        }
      } else {
        console.log(
          `[API] /api/classification/${model}/dataset - HTTP ${datasetResp.status}: ${datasetResp.body.slice(0, 200)}`,
        );
      }

      // Train endpoint
      const trainResp = await httpGet(
        `/api/classification/${encodedModel}/train`,
      );
      if (trainResp.status === 200) {
        try {
          const train = JSON.parse(trainResp.body);
          const entries = Array.isArray(train) ? train : Object.entries(train);
          console.log(`[API] /api/classification/${model}/train`);
          console.log(
            `  Type: ${Array.isArray(train) ? "array" : typeof train}, length/keys: ${Array.isArray(train) ? train.length : Object.keys(train).length}`,
          );
          console.log(
            `  First 5 entries:\n${JSON.stringify(entries.slice(0, 5), null, 2)}`,
          );
        } catch (e) {
          console.log(`  Failed to parse train: ${e.message}`);
        }
      } else {
        console.log(
          `[API] /api/classification/${model}/train - HTTP ${trainResp.status}: ${trainResp.body.slice(0, 200)}`,
        );
      }

      // Try to get a thumbnail URL to understand the image src pattern
      if (trainResp.status === 200) {
        try {
          const train = JSON.parse(trainResp.body);
          const firstFile = Array.isArray(train) ? train[0] : null;
          if (firstFile) {
            // Try various thumbnail URL patterns
            const patterns = [
              `/api/classification/${encodedModel}/train/${firstFile}/thumbnail.jpg`,
              `/api/classification/${encodedModel}/train/${firstFile}`,
              `/clips/${encodedModel}/train/${firstFile}`,
            ];
            for (const p of patterns) {
              const resp = await httpGet(p);
              console.log(
                `  Thumbnail URL test: ${p} -> HTTP ${resp.status} (content-type: ${resp.headers["content-type"]}, size: ${resp.body.length})`,
              );
            }
          }
        } catch (_) {}
      }
    }

    // ================================================================
    // HTML/DOM INSPECTION
    // ================================================================
    console.log("\n" + "=".repeat(80));
    console.log("HTML / DOM INSPECTION");
    console.log("=".repeat(80));

    // Fetch the main classification page HTML
    const classifPageResp = await httpGet("/classification");
    console.log(
      `\n[HTML] /classification - HTTP ${classifPageResp.status} (${classifPageResp.body.length} bytes)`,
    );

    // This is likely a React SPA, so the HTML will be minimal. Let's check.
    const html = classifPageResp.body;
    console.log(`[HTML] First 2000 chars:\n${html.slice(0, 2000)}`);

    // Check for any JS bundle references (to find source maps or component names)
    const scriptMatches = html.match(/<script[^>]*src="([^"]+)"[^>]*>/g) || [];
    console.log(`\n[HTML] Script tags: ${scriptMatches.length}`);
    for (const s of scriptMatches) {
      console.log(`  ${s}`);
    }

    // Fetch the main JS bundle to look for classification component code
    const jsMatch = html.match(/src="(\/assets\/[^"]+\.js)"/);
    if (jsMatch) {
      console.log(`\n[JS] Fetching main bundle: ${jsMatch[1]}`);
      const jsResp = await httpGet(jsMatch[1]);
      if (jsResp.status === 200) {
        const js = jsResp.body;
        console.log(`[JS] Bundle size: ${js.length} bytes`);

        // Search for classification-related code patterns
        const searchTerms = [
          "classify image as",
          "Classify image as",
          "categorize",
          "/classification/",
          "dataset/categorize",
          "training_file",
          "train/delete",
          "ModelTraining",
          "classification",
        ];
        for (const term of searchTerms) {
          const idx = js.indexOf(term);
          if (idx !== -1) {
            const context = js.slice(Math.max(0, idx - 200), idx + 200);
            console.log(`\n[JS] Found "${term}" at offset ${idx}:`);
            console.log(`  ...${context}...`);
          }
        }

        // Look for the dropdown/select implementation
        const selectTerms = [
          "combobox",
          "listbox",
          "SelectTrigger",
          "SelectContent",
          "SelectItem",
          "Select>",
          "DropdownMenu",
        ];
        for (const term of selectTerms) {
          const idx = js.indexOf(term);
          if (idx !== -1) {
            const context = js.slice(Math.max(0, idx - 150), idx + 150);
            console.log(`\n[JS] Found "${term}" at offset ${idx}:`);
            console.log(`  ...${context}...`);
          }
        }
      }
    }

    // Also check if there are multiple JS chunks
    const allJsMatches =
      html.match(/src="(\/assets\/[^"]+\.js)"/g) || [];
    console.log(`\n[JS] All JS assets: ${allJsMatches.length}`);
    for (const m of allJsMatches) {
      const path = m.match(/src="([^"]+)"/)?.[1];
      if (path) console.log(`  ${path}`);
    }

    // Try to fetch the Frigate source for classification view from GitHub
    console.log("\n" + "=".repeat(80));
    console.log("FRIGATE VERSION");
    console.log("=".repeat(80));

    const versionResp = await httpGet("/api/version");
    if (versionResp.status === 200) {
      console.log(`[API] Frigate version: ${versionResp.body}`);
    }

    console.log("\n" + "=".repeat(80));
    console.log("INSPECTION COMPLETE");
    console.log("=".repeat(80));
  } catch (err) {
    console.error(`\n[ERROR] ${err.message}`);
    console.error(err.stack);
  } finally {
    if (portForwardProc) {
      console.log("\n[cleanup] Killing port-forward...");
      portForwardProc.kill("SIGTERM");
    }
  }
}

main().catch(console.error);
