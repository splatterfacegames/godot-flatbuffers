const loadButton = document.querySelector("[data-load-demo]");
const demoStage = document.querySelector("[data-demo-stage]");

loadButton?.addEventListener("click", () => {
  const frame = document.createElement("iframe");
  frame.src = "/demo/";
  frame.title = "godot-flatbuffers interactive Godot demo";
  frame.allow = "autoplay; fullscreen; gamepad";
  demoStage.append(frame);
  frame.focus();
});
