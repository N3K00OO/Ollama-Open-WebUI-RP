# RAG Changelog

## feature/rag-docling-qdrant-bge

- Added optional local Qdrant startup for Open WebUI vector storage.
- Added optional local Docling Serve startup for document extraction and OCR.
- Set multilingual RAG embedding defaults to `intfloat/multilingual-e5-large-instruct`.
- Enabled Open WebUI hybrid RAG search by default when the RAG stack is enabled.
- Set local reranking defaults to `BAAI/bge-reranker-v2-m3` with a conservative batch size.
- Added `DISABLE_RAG_STACK=True` as an emergency kill switch.
- Added `scripts/check-rag-stack.sh` for local runtime health checks.
- Documented PersistentConfig caveats and low-memory RAG settings.
