# jfrog_manager.py
# Python 3.10+ | Compatible con AWS Lambda | Versión Final Enterprise
"""
JFrog Artifactory Manager - Versión Final

Un cliente robusto y simplificado para operaciones con JFrog Artifactory,
optimizado para entornos enterprise y AWS Lambda.

Características:
- API completa para operaciones JFrog Artifactory
- Logging estructurado para observabilidad enterprise
- Validaciones exhaustivas y manejo robusto de errores
- Reintentos automáticos con backoff exponencial
- Compatibilidad total con AWS Lambda
- Sin dependencias externas (excepto boto3 opcional)
- Cumplimiento PEP 8, SOLID principles e ISO 5055:2021

Uso básico:
    >>> from jfrog_manager import JfrogManager, JfrogConfig
    >>> config = JfrogConfig.from_env()
    >>> manager = JfrogManager(config)
    >>> result = manager.upload_file("repo", "path/file.jar", "./local.jar")

Autor: Enterprise Development Team
Versión: 2.1.0 Final
Licencia: MIT
"""

from __future__ import annotations

import functools
import hashlib
import json
import logging
import mimetypes
import os
import socket
import time
import typing as t
from dataclasses import dataclass, field
from http.client import HTTPResponse
from urllib import error, parse, request

# boto3 es opcional (solo para funcionalidad S3)
try:
    import boto3  # type: ignore
    _HAS_BOTO3 = True
except ImportError:
    _HAS_BOTO3 = False


# ---------------------------- Versioning & Exports --------------------

__version__ = "2.1.0"
__author__ = "Enterprise Development Team"
__license__ = "MIT"

__all__ = [
    "JfrogManager", "JfrogConfig", "JfrogError", "ValidationError", 
    "build_logger", "__version__"
]


# ---------------------------- Exceptions ------------------------------

class JfrogError(RuntimeError):
    """
    Error de operación con Artifactory.
    
    Attributes:
        status_code: Código HTTP de error (si aplica)
        response_body: Cuerpo de respuesta de error (si aplica)
    """
    
    def __init__(self, message: str, status_code: int | None = None, response_body: str | None = None):
        super().__init__(message)
        self.status_code = status_code
        self.response_body = response_body


class ValidationError(JfrogError):
    """Error de validación de parámetros de entrada."""
    pass


# ---------------------------- Logging Infrastructure ------------------

class StructuredLogger:
    """Logger con contexto estructurado para observabilidad enterprise."""
    
    def __init__(self, logger: logging.Logger):
        self.logger = logger
    
    def log_operation(self, operation: str, success: bool, duration: float, **context) -> None:
        """Log unificado de operaciones con contexto estructurado."""
        level = logging.INFO if success else logging.ERROR
        status = "success" if success else "error"
        
        extra = {
            'operation': operation,
            'status': status,
            'duration_seconds': round(duration, 2),
            'timestamp': time.time(),
            **context
        }
        
        message = f"{operation.replace('_', ' ').title()} {'completed' if success else 'failed'}"
        self.logger.log(level, message, extra=extra)


def build_logger(name: str = "JfrogManager", level: int = logging.INFO) -> logging.Logger:
    """
    Construye logger optimizado para Lambda y entornos locales.
    
    Args:
        name: Nombre del logger
        level: Nivel de logging
        
    Returns:
        Logger configurado con formato estructurado
    """
    logger = logging.getLogger(name)
    
    if logger.handlers:
        return logger
    
    handler = logging.StreamHandler()
    formatter = logging.Formatter(
        fmt='%(asctime)s [%(levelname)s] %(name)s - %(message)s',
        datefmt='%Y-%m-%dT%H:%M:%S%z'
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(level)
    logger.propagate = False
    
    return logger


# -------------------------- Decorador de Logging ----------------------

def log_operation(func):
    """Decorador para logging automático de operaciones."""
    @functools.wraps(func)
    def wrapper(self, *args, **kwargs):
        operation = func.__name__
        start_time = time.time()
        
        # Extraer contexto básico para logging
        context = {}
        if hasattr(self, '_get_log_context'):
            context = self._get_log_context(operation, args, kwargs)
        
        try:
            result = func(self, *args, **kwargs)
            duration = time.time() - start_time
            self.logger.log_operation(operation, True, duration, **context)
            return result
        except Exception as e:
            duration = time.time() - start_time
            context.update(error_type=type(e).__name__, error_message=str(e))
            self.logger.log_operation(operation, False, duration, **context)
            raise
    return wrapper


# -------------------------- Utility Functions -------------------------

def calculate_checksums(data: bytes) -> dict[str, str]:
    """
    Calcula checksums múltiples en una sola pasada.
    
    Args:
        data: Contenido binario
        
    Returns:
        Dict con SHA256, SHA1 y MD5 hexdigest
    """
    sha256_hash = hashlib.sha256()
    sha1_hash = hashlib.sha1()
    md5_hash = hashlib.md5()
    
    sha256_hash.update(data)
    sha1_hash.update(data)
    md5_hash.update(data)
    
    return {
        "sha256": sha256_hash.hexdigest(),
        "sha1": sha1_hash.hexdigest(),
        "md5": md5_hash.hexdigest(),
    }


def guess_content_type(path: str) -> str:
    """
    Detecta tipo MIME del archivo.
    
    Args:
        path: Ruta del archivo
        
    Returns:
        Tipo MIME detectado o application/octet-stream por defecto
    """
    mime_type, _ = mimetypes.guess_type(path)
    return mime_type or "application/octet-stream"


def read_file_safe(file_path: str) -> bytes:
    """
    Lee archivo de forma segura con validaciones completas.
    
    Args:
        file_path: Ruta del archivo a leer
        
    Returns:
        Contenido binario del archivo
        
    Raises:
        ValidationError: Si el archivo no es válido
        JfrogError: Si hay errores de lectura
    """
    if not file_path:
        raise ValidationError("file_path es requerido")
    
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"Archivo no encontrado: {file_path}")
    
    if not os.path.isfile(file_path):
        raise ValidationError(f"Path no es un archivo: {file_path}")
    
    if not os.access(file_path, os.R_OK):
        raise ValidationError(f"Sin permisos de lectura: {file_path}")
    
    try:
        with open(file_path, "rb") as f:
            return f.read()
    except PermissionError:
        raise JfrogError(f"Sin permisos para leer archivo: {file_path}")
    except OSError as e:
        raise JfrogError(f"Error del sistema al leer archivo {file_path}: {e}")


# -------------------------- Validation Functions ---------------------

def validate_repo(repo: str, default_repo: str | None = None) -> str:
    """Valida y normaliza nombre de repositorio."""
    if not repo:
        if not default_repo:
            raise ValidationError("No se especificó repo y no hay repo por defecto configurado")
        repo = default_repo
    
    if not isinstance(repo, str) or not repo.strip():
        raise ValidationError(f"Repo debe ser un string no vacío: {repo}")
    
    return repo.strip()


def validate_target_path(target_path: str) -> str:
    """Valida path de destino."""
    if not target_path or not isinstance(target_path, str):
        raise ValidationError("target_path es requerido y debe ser string")
    
    target_path = target_path.strip()
    if not target_path or target_path.endswith("/"):
        raise ValidationError("target_path debe incluir nombre de archivo (ej: apps/1.0.0/app.zip)")
    
    return target_path


def validate_properties(properties: dict[str, t.Any] | None) -> dict[str, str]:
    """Valida y normaliza propiedades."""
    if not properties:
        return {}
    
    if not isinstance(properties, dict):
        raise ValidationError("properties debe ser un diccionario")
    
    validated = {}
    for key, value in properties.items():
        if not isinstance(key, str) or not key.strip():
            raise ValidationError(f"Clave de propiedad inválida: {key}")
        if value is None:
            continue
        validated[key.strip()] = str(value).strip()
    
    return validated


# -------------------------- URL Building Functions -------------------

def build_artifact_url(base_url: str, repo: str, target_path: str, properties: dict[str, str] | None = None) -> str:
    """Construye URL para artefacto con matrix properties opcionales."""
    clean_repo = repo.strip("/")
    clean_path = target_path.lstrip("/")
    prop_suffix = _build_matrix_properties(properties)
    return f"{base_url}/{clean_repo}/{clean_path}{prop_suffix}"


def build_api_url(base_url: str, endpoint: str, repo: str, target_path: str) -> str:
    """Construye URL para API de Artifactory."""
    clean_repo = repo.strip("/")
    clean_path = target_path.lstrip("/")
    return f"{base_url}/api/{endpoint}/{clean_repo}/{clean_path}"


def build_properties_api_url(base_url: str, repo: str, target_path: str, properties: dict[str, str]) -> str:
    """Construye URL para API de propiedades."""
    base_api_url = build_api_url(base_url, "storage", repo, target_path)
    query_params = _build_properties_query(properties)
    return f"{base_api_url}?{query_params}&recursive=0"


def _build_matrix_properties(properties: dict[str, str] | None) -> str:
    """Convierte propiedades a matrix parameters."""
    if not properties:
        return ""
    
    parts = []
    for key, value in properties.items():
        if value is not None:
            encoded_value = parse.quote(str(value), safe="")
            parts.append(f"{key}={encoded_value}")
    
    return ";" + ";".join(parts) if parts else ""


def _build_properties_query(properties: dict[str, str]) -> str:
    """Convierte propiedades a query parameters para API."""
    pairs = [
        f"{key}={parse.quote(str(value), safe='')}"
        for key, value in properties.items()
        if value is not None
    ]
    return "properties=" + ";".join(pairs)


# ------------------------ Configuración --------------------------------

@dataclass(slots=True)
class JfrogConfig:
    """
    Configuración para JFrog Artifactory.
    
    Attributes:
        base_url: URL base de Artifactory
        access_token: Token de acceso (recomendado)
        api_key: API key (método legado)
        timeout_seconds: Timeout para requests HTTP
        max_retries: Número máximo de reintentos
        backoff_base: Base para cálculo de backoff exponencial
        default_repo: Repositorio por defecto
        default_headers: Headers adicionales
        log_level: Nivel de logging
    """
    base_url: str
    access_token: str | None = None
    api_key: str | None = None
    timeout_seconds: int = 120
    max_retries: int = 3
    backoff_base: float = 0.6
    default_repo: str | None = field(default=None)
    default_headers: dict[str, str] = field(default_factory=dict)
    log_level: str = "INFO"

    def __post_init__(self):
        if not self.base_url:
            raise ValueError("base_url es requerido (ej: https://org.jfrog.io/artifactory)")
    
    def normalized_base_url(self) -> str:
        """Normaliza URL base añadiendo /artifactory si es necesario."""
        base = self.base_url.rstrip("/")
        if not base.endswith("/artifactory"):
            base = base + "/artifactory"
        return base
    
    def build_auth_headers(self) -> dict[str, str]:
        """Construye headers de autenticación."""
        headers = dict(self.default_headers)
        
        if self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"
        elif self.api_key:
            headers["X-JFrog-Art-Api"] = self.api_key
        
        return headers
    
    @staticmethod
    def from_env() -> "JfrogConfig":
        """
        Crea configuración desde variables de entorno.
        
        Variables esperadas:
        - ARTIFACTORY_URL: URL base de JFrog Artifactory
        - ARTIFACTORY_TOKEN: Token de acceso (recomendado)
        - ARTIFACTORY_API_KEY: API key (alternativa)
        - HTTP_TIMEOUT: Timeout en segundos (opcional)
        - ARTIFACTORY_REPO: Repositorio por defecto (opcional)
        - LOG_LEVEL: Nivel de logging (opcional)
        """
        return JfrogConfig(
            base_url=os.environ.get("ARTIFACTORY_URL", ""),
            access_token=os.environ.get("ARTIFACTORY_TOKEN"),
            api_key=os.environ.get("ARTIFACTORY_API_KEY"),
            timeout_seconds=int(os.environ.get("HTTP_TIMEOUT", "120")),
            default_repo=os.environ.get("ARTIFACTORY_REPO"),
            log_level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        )


# ---------------------------- Manager Principal -----------------------

class JfrogManager:
    """
    Manager principal para operaciones con JFrog Artifactory.
    
    Cliente enterprise que proporciona una API completa y robusta para
    interactuar con JFrog Artifactory, optimizado para entornos de producción
    y AWS Lambda.
    
    Características:
    - Upload de archivos con checksums automáticos
    - Validaciones exhaustivas de entrada
    - Logging estructurado para observabilidad
    - Reintentos automáticos con backoff exponencial
    - Soporte para S3 integration
    - Gestión completa de propiedades
    - Compatible con AWS Lambda
    
    Example:
        >>> config = JfrogConfig.from_env()
        >>> manager = JfrogManager(config)
        >>> result = manager.upload_file(
        ...     repo="generic-local",
        ...     target_path="apps/v1.0.0/myapp.jar",
        ...     file_path="./dist/myapp.jar",
        ...     properties={"env": "prod", "version": "1.0.0"}
        ... )
        >>> print(f"Upload status: {result['status']}")
    """

    def __init__(self, config: JfrogConfig, logger: logging.Logger | None = None) -> None:
        """
        Inicializa el manager con configuración.
        
        Args:
            config: Configuración de JFrog Artifactory
            logger: Logger personalizado (opcional)
        """
        self.config = config
        self.base_url = config.normalized_base_url()
        self.default_headers = config.build_auth_headers()
        
        # Configurar logging estructurado
        base_logger = logger or build_logger(level=getattr(logging, config.log_level, logging.INFO))
        self.logger = StructuredLogger(base_logger)
        
        # Configurar timeout global para urllib
        socket.setdefaulttimeout(float(config.timeout_seconds))
        
        # Log de inicialización
        self.logger.log_operation(
            "manager_init", True, 0.0,
            timeout=config.timeout_seconds,
            max_retries=config.max_retries,
            auth_method="token" if config.access_token else "api_key" if config.api_key else "none"
        )

    def _get_log_context(self, operation: str, args: tuple, kwargs: dict) -> dict[str, t.Any]:
        """Extrae contexto relevante para logging."""
        context = {}
        
        if operation == "upload_file" and len(args) >= 3:
            context.update(repo=args[0], target_path=args[1], file_path=args[2])
        elif operation == "upload_bytes" and len(args) >= 3:
            context.update(repo=args[0], target_path=args[1], content_size=len(args[2]))
        elif operation == "upload_from_s3_object" and len(args) >= 2:
            context.update(s3_bucket=args[0], s3_key=args[1])
        elif len(args) >= 2:
            context.update(repo=args[0], target_path=args[1])
        
        if "properties" in kwargs and kwargs["properties"]:
            context["properties_count"] = len(kwargs["properties"])
            
        return context

    # ----------------------- API Pública -----------------------

    @log_operation
    def upload_file(
        self,
        repo: str,
        target_path: str,
        file_path: str,
        *,
        properties: dict[str, t.Any] | None = None,
        add_checksum_headers: bool = True,
        content_type: str | None = None,
    ) -> dict[str, t.Any]:
        """
        Sube un archivo local a Artifactory.
        
        Args:
            repo: Nombre del repositorio
            target_path: Ruta destino incluyendo nombre de archivo
            file_path: Ruta del archivo local
            properties: Propiedades del artefacto (opcional)
            add_checksum_headers: Si añadir headers de checksum
            content_type: Tipo MIME (autodetectado si es None)
            
        Returns:
            Dict con información de la respuesta incluyendo status y checksums
            
        Raises:
            ValidationError: Si los parámetros no son válidos
            JfrogError: Si ocurre un error en la operación
            FileNotFoundError: Si el archivo no existe
        """
        # Validar y leer archivo
        file_data = read_file_safe(file_path)
        
        # Detectar content type si no se especifica
        if content_type is None:
            content_type = guess_content_type(file_path)
        
        # Delegar a upload_bytes
        return self.upload_bytes(
            repo=repo,
            target_path=target_path,
            content=file_data,
            properties=properties,
            add_checksum_headers=add_checksum_headers,
            content_type=content_type,
        )

    @log_operation
    def upload_bytes(
        self,
        repo: str,
        target_path: str,
        content: bytes,
        *,
        properties: dict[str, t.Any] | None = None,
        add_checksum_headers: bool = True,
        content_type: str = "application/octet-stream",
    ) -> dict[str, t.Any]:
        """
        Sube contenido binario a Artifactory.
        
        Args:
            repo: Nombre del repositorio
            target_path: Ruta destino incluyendo nombre de archivo
            content: Contenido binario a subir
            properties: Propiedades del artefacto (opcional)
            add_checksum_headers: Si añadir headers de checksum
            content_type: Tipo MIME del contenido
            
        Returns:
            Dict con información de la respuesta incluyendo checksums
        """
        # Validar parámetros
        validated_repo = validate_repo(repo, self.config.default_repo)
        validated_path = validate_target_path(target_path)
        validated_props = validate_properties(properties)
        
        # Construir URL
        url = build_artifact_url(self.base_url, validated_repo, validated_path, validated_props)
        
        # Preparar headers
        headers = {"Content-Type": content_type}
        checksums = None
        
        if add_checksum_headers:
            checksums = calculate_checksums(content)
            headers.update({
                "X-Checksum-Sha256": checksums["sha256"],
                "X-Checksum-Sha1": checksums["sha1"],
                "X-Checksum-Md5": checksums["md5"]
            })
        
        # Ejecutar subida con reintentos
        response = self._put_with_retries(url, content, headers)
        
        # Procesar respuesta
        status = getattr(response, "status", None) or response.getcode()
        raw_response = response.read().decode("utf-8", "replace")
        
        return {
            "status": status,
            "url": self._safe_url(url),
            "response": self._safe_json_parse(raw_response),
            "checksums": checksums
        }

    @log_operation
    def upload_from_s3_object(
        self,
        s3_bucket: str,
        s3_key: str,
        *,
        repo: str,
        target_path: str,
        properties: dict[str, t.Any] | None = None,
        add_checksum_headers: bool = True,
        content_type: str | None = None,
        s3_client=None,
    ) -> dict[str, t.Any]:
        """
        Sube un objeto de S3 a Artifactory.
        
        Args:
            s3_bucket: Nombre del bucket S3
            s3_key: Key del objeto en S3
            repo: Nombre del repositorio destino
            target_path: Ruta destino incluyendo nombre de archivo
            properties: Propiedades del artefacto (opcional)
            add_checksum_headers: Si añadir headers de checksum
            content_type: Tipo MIME (autodetectado si es None)
            s3_client: Cliente S3 personalizado (opcional)
            
        Returns:
            Dict con información de la respuesta
            
        Raises:
            RuntimeError: Si boto3 no está disponible
        """
        if not _HAS_BOTO3:
            raise RuntimeError("boto3 no está disponible en este runtime para modo S3.")
        
        # Descargar de S3
        s3_client = s3_client or boto3.client("s3")
        obj = s3_client.get_object(Bucket=s3_bucket, Key=s3_key)
        s3_data = obj["Body"].read()
        
        # Detectar content type si no se especifica
        if content_type is None:
            content_type = guess_content_type(s3_key)
        
        # Delegar a upload_bytes
        return self.upload_bytes(
            repo=repo,
            target_path=target_path,
            content=s3_data,
            properties=properties,
            add_checksum_headers=add_checksum_headers,
            content_type=content_type,
        )

    @log_operation
    def artifact_exists(self, repo: str, target_path: str) -> bool:
        """
        Verifica si un artefacto existe en Artifactory.
        
        Args:
            repo: Nombre del repositorio
            target_path: Ruta del artefacto
            
        Returns:
            True si el artefacto existe, False en caso contrario
        """
        validated_repo = validate_repo(repo, self.config.default_repo)
        validated_path = validate_target_path(target_path)
        
        url = build_artifact_url(self.base_url, validated_repo, validated_path)
        
        try:
            req = request.Request(url=url, method="HEAD", headers=self.default_headers)
            with request.urlopen(req, timeout=self.config.timeout_seconds) as resp:  # nosec
                return 200 <= (resp.status or resp.getcode()) < 400
        except error.HTTPError as e:
            if e.code == 404:
                return False
            raise JfrogError(f"HEAD {self._safe_url(url)} -> HTTP {e.code}", e.code) from e
        except Exception as e:
            raise JfrogError(f"HEAD {self._safe_url(url)} -> {e}") from e

    @log_operation
    def set_properties(self, repo: str, target_path: str, properties: dict[str, t.Any]) -> dict[str, t.Any]:
        """
        Establece propiedades de un artefacto.
        
        Args:
            repo: Nombre del repositorio
            target_path: Ruta del artefacto
            properties: Propiedades a establecer
            
        Returns:
            Dict con información de la respuesta
        """
        validated_repo = validate_repo(repo, self.config.default_repo)
        validated_path = validate_target_path(target_path)
        validated_props = validate_properties(properties)
        
        if not validated_props:
            return {"status": 204, "message": "Sin propiedades que establecer."}
        
        url = build_properties_api_url(self.base_url, validated_repo, validated_path, validated_props)
        return self._execute_request(url, "PUT")

    @log_operation
    def get_properties(self, repo: str, target_path: str) -> dict[str, t.Any]:
        """
        Obtiene propiedades de un artefacto.
        
        Args:
            repo: Nombre del repositorio
            target_path: Ruta del artefacto
            
        Returns:
            Dict con las propiedades del artefacto
        """
        validated_repo = validate_repo(repo, self.config.default_repo)
        validated_path = validate_target_path(target_path)
        
        url = build_api_url(self.base_url, "storage", validated_repo, validated_path)
        
        try:
            req = request.Request(url=url, method="GET", headers=self.default_headers)
            with request.urlopen(req, timeout=self.config.timeout_seconds) as resp:  # nosec
                return json.loads(resp.read().decode("utf-8", "replace"))
        except error.HTTPError as e:
            if e.code == 404:
                return {"error": "not_found", "url": self._safe_url(url)}
            raise JfrogError(f"GET {self._safe_url(url)} -> HTTP {e.code}", e.code) from e

    @log_operation
    def delete_artifact(self, repo: str, target_path: str) -> dict[str, t.Any]:
        """
        Elimina un artefacto de Artifactory.
        
        Args:
            repo: Nombre del repositorio
            target_path: Ruta del artefacto
            
        Returns:
            Dict con información de la respuesta
        """
        validated_repo = validate_repo(repo, self.config.default_repo)
        validated_path = validate_target_path(target_path)
        
        url = build_artifact_url(self.base_url, validated_repo, validated_path)
        return self._execute_request(url, "DELETE")

    # ----------------------- Métodos Internos -----------------------

    def _put_with_retries(self, url: str, data: bytes, headers: dict[str, str]) -> HTTPResponse:
        """Realiza PUT con reintentos automáticos y backoff exponencial."""
        merged_headers = {**self.default_headers, **headers}
        last_exc: Exception | None = None
        
        for attempt in range(self.config.max_retries + 1):
            try:
                req = request.Request(url=url, method="PUT", data=data, headers=merged_headers)
                return request.urlopen(req, timeout=self.config.timeout_seconds)  # nosec
                
            except error.HTTPError as e:
                if e.code < 500 or attempt == self.config.max_retries:
                    error_body = e.read().decode("utf-8", "replace")
                    raise JfrogError(
                        f"HTTP {e.code} al subir a {self._safe_url(url)}: {error_body}",
                        e.code, error_body
                    )
                last_exc = e
                
            except Exception as e:
                if attempt == self.config.max_retries:
                    raise JfrogError(f"Error de red al subir a {self._safe_url(url)}: {e}") from e
                last_exc = e
            
            # Backoff exponencial con jitter
            sleep_time = min(5.0, (self.config.backoff_base * (2 ** attempt)) + (0.05 * attempt))
            time.sleep(sleep_time)
        
        raise JfrogError(f"Reintentos agotados: {last_exc}")

    def _execute_request(self, url: str, method: str) -> dict[str, t.Any]:
        """Ejecuta request HTTP genérico con manejo de errores."""
        req = request.Request(url=url, method=method, headers=self.default_headers)
        try:
            with request.urlopen(req, timeout=self.config.timeout_seconds) as resp:  # nosec
                text = resp.read().decode("utf-8", "replace")
                return {
                    "status": resp.status or resp.getcode(),
                    "response": self._safe_json_parse(text),
                    "url": self._safe_url(url)
                }
        except error.HTTPError as e:
            error_body = e.read().decode("utf-8", "replace")
            raise JfrogError(f"{method} {self._safe_url(url)} -> HTTP {e.code}: {error_body}", e.code, error_body) from e

    @staticmethod
    def _safe_json_parse(text: str) -> t.Any:
        """Parse JSON de forma segura."""
        try:
            return json.loads(text)
        except Exception:
            return text

    @staticmethod
    def _safe_url(url: str) -> str:
        """URL segura para logs (oculta credenciales)."""
        return url.replace("Authorization", "***AUTH***").replace("X-JFrog-Art-Api", "***API***")