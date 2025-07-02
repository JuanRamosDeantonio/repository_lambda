import logging
import json

from typing import Dict, Any

from uploader_file.services.sender_to_repo import sender_to_repo
from uploader_file.utils.http_responses import create_error_response

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event: Dict[str, Any], context: Any):

    try:

        logger.info("Iniciando ejecución de la lambda")

        body = event.get("body")

        logger.info("Obtención del body en el evento de la lambda: %s", body)

        if isinstance(body, str):
            try:
                body = json.loads(body)
            except json.JSONDecodeError as e:
                raise ValueError(f"JSON inválido en el cuerpo de la solicitud: {e}")

        report = body.get("report")

        logger.info("Obtención del reporte del objeto: %s", report)

        if not report:
            raise ValueError("Falta parámetro requerido: 'report'")
        
        return sender_to_repo(report)
    
    except Exception as e:
        return create_error_response(e)
