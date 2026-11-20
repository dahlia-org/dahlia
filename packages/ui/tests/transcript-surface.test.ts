import { describe, expect, it } from "vitest";
import { pageToRequest, reconcile, type RowContainer } from "../src/content-surface/transcript";

type Node = { id: string };

function list(ids: string[]) {
  const children: Node[] = ids.map((id) => ({ id }));
  let moves = 0;
  const container: RowContainer<Node> = {
    get firstChild() { return children[0] ?? null; },
    nextSibling: (node) => children[children.indexOf(node) + 1] ?? null,
    insertBefore: (node, before) => {
      const index = children.indexOf(node);
      if (index >= 0) children.splice(index, 1);
      else moves -= 1; // inserting a new node is not a move
      moves += 1;
      children.splice(before ? children.indexOf(before) : children.length, 0, node);
    },
    remove: (node) => { children.splice(children.indexOf(node), 1); },
  };
  const nodes = new Map(children.map((node) => [node.id, node]));
  return { container, nodes, ids: () => children.map((node) => node.id), moves: () => moves };
}

describe("transcript surface", () => {
  it("appends, prepends, and removes rows without moving rows already in place", () => {
    const rows = list(["b", "c", "d"]);
    rows.nodes.set("a", { id: "a" });
    rows.nodes.set("e", { id: "e" });
    reconcile(rows.container, rows.nodes, ["a", "b", "c", "e"]);
    expect(rows.ids()).toEqual(["a", "b", "c", "e"]);
    expect(rows.nodes.has("d")).toBe(false);
    expect(rows.moves()).toBe(0);
  });

  it("moves a row whose position changed", () => {
    const rows = list(["a", "b", "c"]);
    reconcile(rows.container, rows.nodes, ["b", "a", "c"]);
    expect(rows.ids()).toEqual(["b", "a", "c"]);
  });

  it("requests the page on the near side only when more rows exist", () => {
    expect(pageToRequest(100, 5000, true, true)).toBe("earlier");
    expect(pageToRequest(100, 5000, false, true)).toBeNull();
    expect(pageToRequest(5000, 100, true, true)).toBe("later");
    expect(pageToRequest(5000, 5000, true, true)).toBeNull();
  });
});
