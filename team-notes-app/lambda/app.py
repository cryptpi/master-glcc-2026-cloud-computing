import base64
import json
import os
import time
import uuid

import boto3
from boto3.dynamodb.conditions import Key

table = boto3.resource("dynamodb").Table(os.environ["TABLE"])
HERE = os.path.dirname(__file__)


def reply(status, body="", content_type="application/json"):
    if not isinstance(body, str):
        body = json.dumps(body)
    return {"statusCode": status, "headers": {"Content-Type": content_type}, "body": body}


def handler(event, context):
    route = event["routeKey"]

    # Public route: the web page. Cognito settings are injected at runtime.
    if route == "GET /":
        with open(os.path.join(HERE, "index.html"), encoding="utf-8") as f:
            page = f.read()
        page = page.replace("__CLIENT_ID__", os.environ["CLIENT_ID"])
        page = page.replace("__REGION__", os.environ["REGION"])
        return reply(200, page, "text/html; charset=utf-8")

    # Everything below is protected by the Cognito JWT authorizer, so "sub"
    # is the verified id of the logged-in user. This is the multi-tenancy rule:
    # every query below is scoped to that id, so users only see their own data.
    user_id = event["requestContext"]["authorizer"]["jwt"]["claims"]["sub"]
    print(json.dumps({"route": route, "user": user_id}))  # visible in CloudWatch Logs

    if route == "GET /notes":
        items = table.query(KeyConditionExpression=Key("user_id").eq(user_id))["Items"]
        items.sort(key=lambda n: n["created"], reverse=True)
        return reply(200, [{"id": n["note_id"], "text": n["text"], "created": n["created"]} for n in items])

    if route == "POST /notes":
        raw = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode("utf-8")
        try:
            text = str(json.loads(raw).get("text", "")).strip()
        except (ValueError, AttributeError):
            return reply(400, {"error": "Invalid JSON"})
        if not text or len(text) > 500:
            return reply(400, {"error": "A note must be 1-500 characters"})
        note = {
            "user_id": user_id,
            "note_id": uuid.uuid4().hex,
            "text": text,
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        table.put_item(Item=note)
        return reply(201, {"id": note["note_id"], "text": note["text"], "created": note["created"]})

    if route == "DELETE /notes/{id}":
        table.delete_item(Key={"user_id": user_id, "note_id": event["pathParameters"]["id"]})
        return reply(204)

    return reply(404, {"error": "Not found"})
