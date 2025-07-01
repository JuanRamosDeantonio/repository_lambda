import json

def create_success_response(message):

    status_code = 200

    json_body = json.dumps(message, ensure_ascii=False, separators=(',',':'))

    return {
        "statusCode": status_code,
        "body": json_body
    }

def create_error_response(message):
    
    status_code = 500

    return {
        "statusCode": status_code,
        "body": message
    }