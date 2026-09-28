"""Dahlia's public ID vectors against the pinned upstream contracts, without a live bank."""

import json
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from hindsight_api import MemoryEngine, RequestContext
from hindsight_api.api.http import RetainRequest
from hindsight_api.engine.retain.bank_utils import validate_new_bank_id

VECTORS = json.loads((Path(__file__).resolve().parents[3] / "test-fixtures/typeid.json").read_text())


@pytest.mark.parametrize("vector", VECTORS, ids=lambda vector: vector["suffix"])
def test_fixed_upstream_accepts_dahlia_banks_and_document_typeids(vector):
    # The suffix comes from the shared encoder fixture; Python adds no ID conversion implementation.
    for kind in ("ws", "user"):
        validate_new_bank_id(f"dahlia_{kind}_{vector['suffix']}")
    for kind, prefix in (("meeting", "mtg"), ("shared", "smem")):
        document_id = f"{prefix}_{vector['suffix']}"
        metadata = {"source_kind": kind, "source_id": vector["uuid"], "source_revision": "1"}
        request = RetainRequest.model_validate(
            {
                "async": True,
                "items": [
                    {
                        "document_id": document_id,
                        "content": "Synthetic canonical content",
                        "metadata": metadata,
                        "update_mode": "replace",
                    }
                ],
            }
        )
        assert request.items[0].document_id == document_id
        assert request.items[0].metadata == metadata
        assert request.items[0].content == "Synthetic canonical content"


@pytest.mark.parametrize("bank_kind,document_kind", [("ws", "mtg"), ("ws", "smem"), ("user", "smem")])
async def test_reprocess_preserves_the_bank_document_and_operation_id(bank_kind, document_kind):
    vector = VECTORS[2]
    bank = f"dahlia_{bank_kind}_{vector['suffix']}"
    document = f"{document_kind}_{vector['suffix']}"
    operation = vector["uuid"]
    engine = object.__new__(MemoryEngine)
    engine._authenticate_tenant = AsyncMock()
    engine._operation_validator = None
    engine.get_document = AsyncMock(
        return_value={
            "original_text": "Synthetic canonical content",
            "retain_params": {"metadata": {"source_id": vector["uuid"], "source_revision": "1"}},
            "tags": [],
        }
    )
    engine.submit_async_retain = AsyncMock(return_value={"operation_id": operation})
    context = RequestContext()
    result = await engine.reprocess_document(bank, document, request_context=context, operation_id=operation)
    assert result["operation_id"] == operation
    call = engine.submit_async_retain.call_args
    assert call.args[0] == bank
    assert call.args[1][0]["document_id"] == document
    assert call.args[1][0]["metadata"]["source_id"] == vector["uuid"]
    assert call.kwargs["operation_id"] == operation
