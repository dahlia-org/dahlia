import type { GatewayModelList } from "@dahlia-ai/ui/model/gateway-models";

export type { GatewayModelList };

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
  headers?: Headers;
  clientVersion?: string;
  signal: AbortSignal;
}


export interface AIGatewayBackend {
  listModels(request: ListModelsRequest): Promise<GatewayModelList>;
  responses(body: RequestBody, context: RequestContext): Promise<Response>;
}
