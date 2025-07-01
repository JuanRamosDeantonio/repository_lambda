import base64
import requests
import logging
import os

from core.http_responses import create_success_response

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def sender_to_repo(text_to_send : str):

    logger.info("Iniciando funcion service: sender_to_repo con parametro: %s", text_to_send)

    content_to_send = base64.b64encode(text_to_send)

    logger.info("Resultado de codificar en base 64: %s", content_to_send)

    token = os.environ.get('TOKEN_GHUB')
    owner = os.environ.get('OWNER')
    repo = os.environ.get('REPO')
    path = os.environ.get('PATH')

    try:

        headers = {
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github+json"
        }

        api_url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"

        data = {
            "message": "message example",
            "commiter": {"name": "user_example", "email": "email@example.c"},
            "content": content_to_send,
            "branch": "dev"
        }

        response_api = requests.put(url=api_url, headers=headers, data=data)

        if response_api.status_code == 404:
            raise ValueError("Ingreso algo mi compa")
        
        message_to_expose = {
            "message": "Subida de archivo exitosa",
            "response_from_api": response_api
        }
        
        return create_success_response(message_to_expose)
             
    except Exception as e:
        raise ValueError(f"Hubo un fallo durante la ejecución {e}")


