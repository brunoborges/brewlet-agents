"""URL routes of the Runtime Concierge."""

from django.urls import path

from concierge import views

urlpatterns = [
    path("healthz", views.healthz),
    path("readyz", views.readyz),
    path("runtime", views.runtime),
    path("ask", views.ask),
]

handler400 = "concierge.views.bad_request"
handler404 = "concierge.views.not_found"
handler500 = "concierge.views.server_error"
