import { copyFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const app = fileURLToPath(new URL("../", import.meta.url));
const source = join(app, "node_modules", "@mediapipe", "tasks-vision");
const target = join(app, "ui", "camera-backgrounds", "runtime");
for (const name of ["vision_bundle.mjs", "wasm/vision_wasm_module_internal.js", "wasm/vision_wasm_module_internal.wasm"]) {
  await mkdir(dirname(join(target, name)), {recursive: true});
  await copyFile(join(source, name), join(target, name));
}
