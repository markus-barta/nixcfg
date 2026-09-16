def provider_id: "paimos-codex-worker-1";
def project_ref: "project:52e00c70-2165-409d-80af-f9b8ed40ae40";
def append_provider_id:
  if index(provider_id) == null then . + [provider_id] else . end;

def new_provider: {
    kind: "paimos-harness",
    origin: "https://pm.barta.cm",
    credentialFile: "/run/credentials/aithema-workspace.service/paimos-conversation-api-key",
    projectID: "6",
    bindingID: "f465d053-2004-42d0-a45e-d467578c8428",
    bindingRevision: 1,
    trustedIssuer: "https://auth.inspr.at",
    modelId: "gpt-5.6-sol",
    allowedModels: ["gpt-5.6-sol"],
    executionLocation: "cloud",
    allowedDataClasses: ["unclassified"]
  };
if .defaultProvider != "openrouter"
   or (.providers | type) != "object"
   or (.policy | type) != "object"
   or (.policy.allowedProviders | type) != "array"
   or (.policy.allowedProviders | index("openrouter")) == null
   or (.policy.estimatedSpend // false) != false
then error("runtime prerequisites changed; review required") else . end
| if (.providers | has(provider_id)) and .providers[provider_id] != new_provider
  then error("provider id is already bound differently") else . end
| .policy.allowedProviders as $previous_org_providers
| .providers[provider_id] = new_provider
| .policy.allowedProviders = (.policy.allowedProviders | append_provider_id)
| if ((.policy.projects // {}) | has(project_ref)) then
    .policy.projects[project_ref].allowedProviders =
      ((.policy.projects[project_ref].allowedProviders // $previous_org_providers) | append_provider_id)
  else . end
