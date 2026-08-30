export interface ModelAliasInfo {
  alias: string;
  configured?: boolean;
  upstreamModel: string;
  displayName: string | null;
  updateTime?: string;
  enabled: boolean;
}

function modelName(model: ModelAliasInfo): string {
  return model.displayName || model.alias;
}

function compareModels(left: ModelAliasInfo, right: ModelAliasInfo): number {
  if (left.enabled !== right.enabled) return left.enabled ? -1 : 1;

  const nameOrder = modelName(left).localeCompare(modelName(right), undefined, {
    numeric: true,
    sensitivity: "base",
  });
  if (nameOrder !== 0) return nameOrder;

  const updateTimeOrder = (Date.parse(right.updateTime || "") || 0)
    - (Date.parse(left.updateTime || "") || 0);
  if (updateTimeOrder !== 0) return updateTimeOrder;

  return left.upstreamModel.localeCompare(right.upstreamModel);
}

export function filterAndSortModels(models: ModelAliasInfo[], query: string): ModelAliasInfo[] {
  const search = query.trim().toLowerCase();
  return models
    .filter((model) => !search || [modelName(model), model.alias, model.upstreamModel]
      .some((value) => value.toLowerCase().includes(search)))
    .toSorted(compareModels);
}
