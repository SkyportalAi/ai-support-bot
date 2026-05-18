"""FastAPI server exposing the support agent as a streaming chat endpoint."""

import asyncio
import json
from fastapi import FastAPI
from fastapi.responses import StreamingResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from agent.agent import SupportAgent

app = FastAPI()
_sessions: dict[str, SupportAgent] = {}


class ChatRequest(BaseModel):
    session_id: str
    message: str


@app.post("/chat")
async def chat(req: ChatRequest):
    if req.session_id not in _sessions:
        _sessions[req.session_id] = SupportAgent()

    agent = _sessions[req.session_id]

    async def generate():
        response = await asyncio.to_thread(agent.chat, req.message)
        yield f"data: {json.dumps({'text': response, 'escalated': agent.escalated})}\n\n"
        if agent.escalated:
            del _sessions[req.session_id]

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.delete("/session/{session_id}")
async def reset_session(session_id: str):
    _sessions.pop(session_id, None)
    return {"ok": True}


@app.get("/", response_class=HTMLResponse)
async def index():
    with open("static/index.html") as f:
        return f.read()


app.mount("/static", StaticFiles(directory="static"), name="static")
