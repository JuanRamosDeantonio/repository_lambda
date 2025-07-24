import logging
import json
import requests
import os
import base64
import datetime
import sys
from typing import Dict, Any, Optional

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
logger.addHandler(handler)

class GitHubUploader:
    def __init__(self, token: str, owner: str, repo: str):
        self.token = token
        self.owner = owner
        self.repo = repo
        self.base_url = "https://api.github.com"
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json"
        }
    
    def get_file_info(self, file_path: str, branch: str = "main") -> Optional[Dict[str, Any]]:
        """Obtiene información de un archivo existente (para obtener el SHA)"""
        url = f"{self.base_url}/repos/{self.owner}/{self.repo}/contents/{file_path}"
        params = {"ref": branch}
        
        try:
            response = requests.get(url, headers=self.headers, params=params)
            if response.status_code == 200:
                return response.json()
            elif response.status_code == 404:
                return None
            else:
                logger.error(f"Error obteniendo info del archivo: {response.status_code} - {response.text}")
                return None
        except Exception as e:
            logger.error(f"Excepción obteniendo info del archivo: {e}")
            return None
    
    def upload_file(self, file_path: str, content: str, commit_message: str, 
                   branch: str = "main", author_name: str = None, author_email: str = None) -> Dict[str, Any]:
        """Sube o actualiza un archivo en GitHub"""
        
        # Verificar si el archivo ya existe
        existing_file = self.get_file_info(file_path, branch)
        
        # Codificar contenido en base64
        encoded_content = base64.b64encode(content.encode('utf-8')).decode('utf-8')
        
        # Preparar payload
        payload = {
            "message": commit_message,
            "content": encoded_content,
            "branch": branch
        }
        
        # Si el archivo existe, incluir SHA para actualización
        if existing_file:
            payload["sha"] = existing_file["sha"]
            logger.info(f"Archivo existente encontrado, SHA: {existing_file['sha']}")
        
        # Agregar información del autor/committer
        if author_name and author_email:
            author_info = {
                "name": author_name,
                "email": author_email
            }
            payload["author"] = author_info
            payload["committer"] = author_info
        
        # Realizar petición
        url = f"{self.base_url}/repos/{self.owner}/{self.repo}/contents/{file_path}"
        
        logger.info(f"Subiendo archivo a: {url}")
        logger.info(f"Payload: {json.dumps(payload, indent=2)}")
        
        response = requests.put(url, headers=self.headers, json=payload)
        
        if response.status_code in [200, 201]:
            return response.json()
        else:
            error_msg = f"Error subiendo archivo: {response.status_code} - {response.text}"
            logger.error(error_msg)
            raise Exception(error_msg)

def lambda_handler(event: Dict[str, Any], context: Any):
    try:
        logger.info("Iniciando ejecución de la lambda")
        logger.info(f"Evento recibido: {json.dumps(event, indent=2)}")
        
        # Obtener el body del evento
        body = event
        
        # Si el body es un string, parsearlo como JSON
        if isinstance(body, str):
            try:
                body = json.loads(body)
            except json.JSONDecodeError as e:
                error_msg = f"JSON inválido en el cuerpo de la solicitud: {e}"
                logger.error(error_msg)
                return {
                    "statusCode": 400,
                    "body": json.dumps({"error": error_msg})
                }
        
        # Validar que existe el campo report
        report = body.get("report")
        if not report:
            error_msg = "Falta parámetro requerido: 'report'"
            logger.error(error_msg)
            return {
                "statusCode": 400,
                "body": json.dumps({"error": error_msg})
            }
        
        logger.info(f"Report recibido: {report}")
        
        # Validar que report es una lista
        if not isinstance(report, list) and not isinstance(report, str):
            error_msg = "Bad type value for the key"
            logger.error(error_msg)
            return {
                "statusCode": 400,
                "body": json.dumps({"error": error_msg})
            }
        
        # Convertir el arreglo de strings en un solo string con saltos de línea
        if isinstance(report, list):
            file_content = '''\n'''.join(report)
        elif isinstance(report, str):
            file_content = report
        
        logger.info(f"Contenido del archivo generado ({len(file_content)} caracteres)")
        
        # Obtener variables de entorno
        token = os.environ.get('TOKEN_GHUB', "")
        owner = os.environ.get('OWNER', "")
        repo = os.environ.get('REPO', "")
        file_path = os.environ.get('FILE_NAME_REPO', "")  # Valor por defecto
        branch = os.environ.get('BRANCH', "")  # Valor por defecto
        
        # Validar variables de entorno
        missing_vars = []
        if not token:
            missing_vars.append('TOKEN_GHUB')
        if not owner:
            missing_vars.append('OWNER')
        if not repo:
            missing_vars.append('REPO')
        
        if missing_vars:
            error_msg = f"Faltan variables de entorno requeridas: {', '.join(missing_vars)}"
            logger.error(error_msg)
            return {
                "statusCode": 500,
                "body": json.dumps({"error": error_msg})
            }
        
        # Limpiar el path del archivo (remover barras iniciales)
        file_path = file_path.lstrip('/')

        time_stamp = str(datetime.datetime.now()).replace(":", "_")

        file_path_signed = f'reports/file-{time_stamp}.md'
        
        logger.info(f"Configuración: owner={owner}, repo={repo}, file_path={file_path_signed}, branch={branch}")
        
        # Crear instancia del uploader
        uploader = GitHubUploader(token, owner, repo)
        
        # Obtener información adicional del evento
        commit_message = body.get("commit_message", "Actualización automática desde Lambda")
        author_name = body.get("author_name", "Lambda Function")
        author_email = body.get("author_email", "lambda@example.com")
        
        # Subir el archivo
        result = uploader.upload_file(
            file_path=file_path_signed,
            content=file_content,
            commit_message=commit_message,
            branch=branch,
            author_name=author_name,
            author_email=author_email
        )
        
        logger.info("Archivo subido exitosamente")
        
        response_data = {
            "message": "Subida de archivo exitosa",
            "file_path": file_path_signed,
            "commit_sha": result.get("commit", {}).get("sha"),
            "html_url": result.get("content", {}).get("html_url"),
            "lines_uploaded": len(report)
        }
        
        logger.info(f"Respuesta: {json.dumps(response_data, indent=2)}")
        
        return {
            "statusCode": 200,
            "body": json.dumps(response_data)
        }
    
    except Exception as e:
        error_msg = f"Error en la ejecución: {str(e)}"
        logger.error(error_msg, exc_info=True)
        
        return {
            "statusCode": 500,
            "body": json.dumps({
                "error": error_msg,
                "type": type(e).__name__
            })
        }

# Ejemplo de evento de prueba
"""
Evento de ejemplo para probar la lambda:

{
    "report": [
        "# Mi Reporte",
        "",
        "## Resumen",
        "Este es un reporte generado automáticamente.",
        "",
        "## Datos",
        "- Item 1",
        "- Item 2",
        "- Item 3",
        "",
        "## Conclusión",
        "El proceso se ejecutó correctamente."
    ],
    "commit_message": "Actualizar reporte desde Lambda",
    "author_name": "Sistema Automatizado",
    "author_email": "sistema@empresa.com"
}
"""
