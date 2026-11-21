"""ASGI entry point of the Runtime Concierge."""

import os

from django.core.asgi import get_asgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "concierge.settings")

application = get_asgi_application()
