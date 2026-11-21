"""Starts the Concierge: `python -m concierge`."""

import os

import uvicorn


def main() -> None:
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "concierge.settings")
    from django.conf import settings

    from concierge.asgi import application

    # One worker is enough, and uvicorn already shuts down gracefully on SIGTERM (the Pod's stop signal): it stops
    # listening, lets the requests in flight finish for at most the shutdown timeout, then exits. Django's ASGI
    # handler does not speak the lifespan protocol, so that is switched off.
    uvicorn.run(
        application,
        host="0.0.0.0",
        port=settings.PORT,
        lifespan="off",
        access_log=False,
        timeout_graceful_shutdown=settings.SHUTDOWN_TIMEOUT,
    )


if __name__ == "__main__":
    main()
