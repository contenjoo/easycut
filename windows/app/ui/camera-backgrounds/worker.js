let request = null, mode = "waiting", picture = null, modelPromise;
let inference, mask, maskPixels, output, blurred;

function surface(prior, width, height) {
  if (!prior || prior.canvas.width !== width || prior.canvas.height !== height) {
    return new OffscreenCanvas(width, height).getContext("2d");
  }
  return prior;
}

async function loadModel() {
  try {
    const {FilesetResolver, ImageSegmenter} = await import("./runtime/vision_bundle.mjs");
    const files = await FilesetResolver.forVisionTasks(new URL("./runtime/wasm", import.meta.url).href, true);
    const segmenter = await ImageSegmenter.createFromOptions(files, {
      baseOptions: {modelAssetPath: new URL("./model/selfie-segmenter-landscape.tflite", import.meta.url).href, delegate: "CPU"},
      runningMode: "VIDEO", outputConfidenceMasks: true, outputCategoryMask: false,
    });
    return segmenter;
  } catch (error) {
    modelPromise = null;
    throw error;
  }
}

async function configure(change) {
  if (request) postMessage({type: "superseded", id: request.id});
  request = change;
  // Keep the current protected picture visible while the next one loads.
  if (mode !== "image" && mode !== "blur") mode = "waiting";
  let image;
  try {
    if (change.mode !== "off") {
      modelPromise ??= loadModel();
      await modelPromise;
      if (request !== change) return;
    }
    if (change.mode === "image") {
      const response = await fetch(change.url);
      if (!response.ok) throw new Error("배경 이미지를 열 수 없습니다.");
      image = await createImageBitmap(await response.blob());
    }
    if (request !== change) { image?.close(); return; }
    picture?.close();
    picture = image;
    mode = change.mode;
    change.prepared = true;
    // Confirm only after the first frame with this selection reaches the output track.
  } catch (error) {
    if (request !== change) { image?.close(); return; }
    request = null;
    mode = "blocked";
    postMessage({type: "failed", id: change.id, message: String(error.message || error)});
  }
}

function cover(ctx, image, width, height) {
  const scale = Math.max(width / image.width, height / image.height);
  const w = image.width * scale, h = image.height * scale;
  ctx.drawImage(image, (width - w) / 2, (height - h) / 2, w, h);
}

function drawMask(segmenter, frame) {
  const scale = 256 / Math.max(frame.displayWidth, frame.displayHeight);
  inference = surface(inference, Math.max(1, Math.round(frame.displayWidth * scale)), Math.max(1, Math.round(frame.displayHeight * scale)));
  const {width, height} = inference.canvas;
  inference.drawImage(frame, 0, 0, width, height);
  segmenter.segmentForVideo(inference.canvas, frame.timestamp / 1000, result => {
    // The landscape selfie model supplies one confidence plane: 1 means person.
    const plane = result.confidenceMasks[0];
    mask = surface(mask, plane.width, plane.height);
    if (maskPixels?.width !== plane.width || maskPixels.height !== plane.height) maskPixels = mask.createImageData(plane.width, plane.height);
    const confidence = plane.getAsFloat32Array();
    for (let i = 0; i < confidence.length; i++) {
      maskPixels.data[i * 4 + 3] = 255 * Math.min(1, Math.max(0, (confidence[i] - 0.12) / 0.76));
    }
    mask.putImageData(maskPixels, 0, 0);
  });
}

function drawEffect(segmenter, frame) {
  drawMask(segmenter, frame);
  const width = frame.displayWidth, height = frame.displayHeight;
  output = surface(output, width, height);
  output.globalCompositeOperation = "copy";
  output.drawImage(frame, 0, 0, width, height);
  output.globalCompositeOperation = "destination-in";
  output.drawImage(mask.canvas, 0, 0, width, height);
  output.globalCompositeOperation = "destination-over";
  if (mode === "image") {
    cover(output, picture, width, height);
  } else {
    const w = Math.min(320, width), h = Math.max(1, Math.round(w * height / width));
    blurred = surface(blurred, w, h);
    const radius = Math.max(2, Math.round(w / 64)), pad = radius * 3;
    blurred.filter = "blur(" + radius + "px)";
    blurred.drawImage(frame, -pad, -pad, w + 2 * pad, h + 2 * pad);
    output.drawImage(blurred.canvas, 0, 0, width, height);
  }
  return new VideoFrame(output.canvas, {timestamp: frame.timestamp, duration: frame.duration ?? undefined, alpha: "discard"});
}

function neutralFrame(frame) {
  output = surface(output, frame.displayWidth, frame.displayHeight);
  output.globalCompositeOperation = "copy";
  output.fillStyle = "#24272e";
  output.fillRect(0, 0, frame.displayWidth, frame.displayHeight);
  return new VideoFrame(output.canvas, {timestamp: frame.timestamp, duration: frame.duration ?? undefined});
}

async function pump(readable, writable) {
  const reader = readable.getReader(), writer = writable.getWriter();
  try {
    for (;;) {
      const {value: frame, done} = await reader.read();
      if (done) break;
      let processed;
      try {
        const active = request?.prepared ? request : null;
        if (mode === "off") processed = frame;
        else if (mode === "waiting" || mode === "blocked") processed = neutralFrame(frame);
        else {
          const segmenter = await modelPromise;
          try {
            processed = drawEffect(segmenter, frame);
          } catch (error) {
            mode = "blocked";
            const message = String(error.message || error);
            postMessage(active ? {type: "failed", id: active.id, message} : {type: "error", message});
            if (active) request = null;
            processed = neutralFrame(frame);
          }
        }
        const applied = !["waiting", "blocked"].includes(mode);
        await writer.write(processed);
        if (active && active === request && applied) {
          postMessage({type: "ready", id: active.id});
          request = null;
        }
      } finally {
        if (processed && processed !== frame) processed.close();
        frame.close();
      }
    }
    await writer.close();
    postMessage({type:"fatal", message:"카메라 입력이 종료되었습니다."});
  } catch (error) {
    postMessage({type:"fatal", message:String(error.message || error)});
  } finally {
    reader.releaseLock();
    writer.releaseLock();
  }
}

onmessage = ({data}) => {
  if (data.type === "start") void pump(data.readable, data.writable);
  if (data.type === "effect") void configure(data);
};
