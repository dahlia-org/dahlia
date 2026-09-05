import type { CodexModelWire } from "./models";

export interface ResponsesInputItem {
  [key: string]: unknown;
}

export interface RequestBody {
  model: string;
  input?: string | ResponsesInputItem[];
  max_output_tokens?: number | null;
  stream?: boolean | null;
  [key: string]: unknown;
}

export interface RequestContext {
  identity: { userId: string };
  headers: Headers;
  signal: AbortSignal;
  /** Server-resolved override; never populated from client input. */
  upstreamModel?: string;
}

export interface ListModelsRequest {
  signal: AbortSignal;
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

export interface AIGatewayBackend {
  listModels(request: ListModelsRequest): Promise<GatewayModelList>;
  responses(body: RequestBody, context: RequestContext): Promise<Response>;
}
