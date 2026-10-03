// Gateway `/api/v1/models` wire format (OpenAI list plus Codex metadata). Delegated protocols are outside OpenAPI.
export interface CodexModelWire {
  [key: string]: unknown;
  slug: string;
  display_name: string;
  description: string | null;
  default_reasoning_level?: string | null;
  supported_reasoning_levels: Array<{ effort: string; description: string }>;
  shell_type: string;
  visibility: string;
  supported_in_api: boolean;
  priority: number;
  model_messages?: { instructions_template?: string | null; [key: string]: unknown };
}

export interface GatewayModelList {
  object: "list";
  data: Array<{
    id: string;
    object: "model";
    created: number;
    owned_by: string;
    display_name: string;
  }>;
  models: CodexModelWire[];
}
