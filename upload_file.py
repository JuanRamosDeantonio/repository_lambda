#!/usr/bin/env python3
"""
Método simple para subir bytearray a JFrog usando jfrog_manager.py
"""

from jfrog_manager import JfrogManager, JfrogConfig


def upload_bytearray(data: bytearray, repo: str, target_path: str, properties: dict = None):
    """
    Sube un bytearray a JFrog Artifactory.
    
    Args:
        data: Tu bytearray
        repo: Repositorio destino
        target_path: Ruta destino (ej: "apps/file.jar")
        properties: Metadatos opcionales
    
    Returns:
        Resultado del upload
    """
    # Configurar desde variables de entorno
    config = JfrogConfig.from_env()
    manager = JfrogManager(config)
    content_encoded = bytes(data, encoding='utf8')
    
    # Convertir bytearray a bytes y subir
    return manager.upload_bytes(
        repo=repo,
        target_path=target_path,
        content=content_encoded,  # Solo esta conversión
        properties=properties or {}
    )


# Ejemplo de uso
if __name__ == "__main__":
    # Crear bytearray
    content = "Hola mundo desde bytearray!"
    data = bytearray(content.encode('utf-8'))
    
    # Subir
    result = upload_bytearray(
        data=data,
        repo="generic-local",
        target_path="test/hello.txt",
        properties={"version": "1.0"}
    )
    
    print(f"Status: {result['status']}")
    print(f"URL: {result['url']}")