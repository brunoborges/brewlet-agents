"""Starts the Concierge: `python -m concierge`."""

import uvicorn

from concierge.app import app, settings


def main() -> None:
    # One worker is enough, and uvicorn already shuts down gracefully on SIGTERM (the Pod's stop signal): it stops
    # listening, lets the requests in flight finish for at most the shutdown timeout, then exits.
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=settings.port,
        access_log=False,
        timeout_graceful_shutdown=settings.shutdown_timeout,
    )


if __name__ == "__main__":
    main()
