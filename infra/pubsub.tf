resource "google_pubsub_topic" "price_events" {
  name = var.pubsub_topic
}

resource "google_pubsub_topic" "price_events_dead_letter" {
  name = "${var.pubsub_topic}-dead-letter"
}

resource "google_pubsub_subscription" "price_events_sub" {
  name  = "${var.pubsub_topic}-sub"
  topic = google_pubsub_topic.price_events.name

  # Subscriber has 60 seconds to ack before redelivery.
  ack_deadline_seconds = 60

  # Retain unacked messages for 7 days.
  message_retention_duration = "604800s"

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.price_events_dead_letter.id
    max_delivery_attempts = 5
  }
}
