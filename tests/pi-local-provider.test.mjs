import assert from "node:assert/strict";
import test from "node:test";
import {
  appProvider,
  useAppSettings,
} from "../hosts/mbp2607/files/pi-local-provider.js";

test("provider follows the app port/model/context without a fixed sampler", () => {
  const provider = appProvider({
    baseUrl: "http://127.0.0.1:8001/v1",
    model: "app-model",
    contextWindow: 262144,
  });
  assert.equal(provider.baseUrl, "http://127.0.0.1:8001/v1");
  assert.equal(provider.models[0].id, "app-model");
  assert.equal(provider.models[0].contextWindow, 262144);
  assert.equal(provider.models[0].samplingParams, undefined);
  assert.equal(provider.compat.supportsReasoningEffort, false);
  assert.throws(
    () => appProvider({ baseUrl: "https://example.org/v1" }),
    /localhost/,
  );
});

test("Pi defaults cannot override app sampler or reasoning; tools remain intact", () => {
  const original = {
    model: "app-model",
    messages: [{ role: "user", content: "hello" }],
    tools: [{ type: "function", function: { name: "read" } }],
    stream: true,
    max_tokens: 16384,
    temperature: 1,
    top_p: 0.95,
    top_k: 20,
    presence_penalty: 1,
    frequency_penalty: 1,
    reasoning_effort: "medium",
    enable_thinking: false,
    thinking: { type: "disabled" },
    reasoning: { effort: "medium" },
    chat_template_kwargs: {
      enable_thinking: false,
      reasoning_effort: "medium",
      other: true,
    },
  };
  const result = useAppSettings(original, "app-model");
  for (const key of [
    "temperature",
    "top_p",
    "top_k",
    "presence_penalty",
    "frequency_penalty",
    "reasoning_effort",
    "enable_thinking",
    "thinking",
    "reasoning",
  ]) {
    assert.equal(result[key], undefined, key);
  }
  assert.equal(result.max_tokens, 16384);
  assert.equal(result.messages, original.messages);
  assert.equal(result.tools, original.tools);
  assert.equal(result.stream, true);
  assert.deepEqual(result.chat_template_kwargs, { other: true });
  assert.equal(original.chat_template_kwargs.enable_thinking, false);
  assert.equal(original.temperature, 1);
  assert.equal(useAppSettings(original, "different-model"), undefined);
});
