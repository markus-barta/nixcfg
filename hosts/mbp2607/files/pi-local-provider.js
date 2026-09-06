// The app is the source of model settings. Pi supplies conversation and tools.
export function appProvider(connection) {
  const endpoint = new URL(connection.baseUrl);
  if (
    endpoint.protocol !== "http:" ||
    endpoint.hostname !== "127.0.0.1" ||
    endpoint.pathname !== "/v1"
  ) {
    throw new Error("pi-local requires a localhost MTPLX endpoint");
  }
  return {
    api: "openai-completions",
    baseUrl: connection.baseUrl,
    apiKey: "mtplx-local",
    authHeader: true,
    headers: { "x-mtplx-client": "pi" },
    compat: {
      maxTokensField: "max_tokens",
      supportsDeveloperRole: false,
      supportsReasoningEffort: false,
      thinkingFormat: "qwen",
    },
    models: [
      {
        id: connection.model,
        name: `${connection.model} · MTPLX app settings`,
        contextWindow: connection.contextWindow,
        maxTokens: 16384,
        reasoning: true,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  };
}

export function useAppSettings(payload, model) {
  if (payload.model !== model) return undefined;
  const request = { ...payload };
  // Pi can inject defaults even without --thinking. Omitting these fields lets
  // live edits in the app take effect on the very next tool/model request.
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
    delete request[key];
  }
  if (request.chat_template_kwargs) {
    request.chat_template_kwargs = { ...request.chat_template_kwargs };
    delete request.chat_template_kwargs.enable_thinking;
    delete request.chat_template_kwargs.reasoning_effort;
  }
  return request;
}

export default function piLocalProvider(pi) {
  if (!process.env.PI_LOCAL_CONNECTION) return;
  const connection = JSON.parse(process.env.PI_LOCAL_CONNECTION);
  pi.registerProvider("mtplx", appProvider(connection));
  pi.on("before_provider_request", (event) =>
    useAppSettings(event.payload, connection.model),
  );
}
