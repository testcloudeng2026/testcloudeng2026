import os
from fastapi import FastAPI

app = FastAPI(title="hello-platform")

APP_NAME = os.getenv("APP_NAME", "hello-platform")
ENVIRONMENT = os.getenv("ENVIRONMENT", "dev")
VERSION = os.getenv("VERSION", "1.0.0")


@app.get("/")
def root():
    return {
        "application": APP_NAME,
        "environment": ENVIRONMENT,
        "version": VERSION,
    }


@app.get("/health")
def health():
    return {"status": "healthy"}
