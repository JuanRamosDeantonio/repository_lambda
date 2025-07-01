# Script PowerShell para empaquetar función AWS Lambda con compresión óptima, validación, control de tamaño y logging persistente

# Configuración de PowerShell para mejor manejo de errores
$ErrorActionPreference = "Stop"

# Obtener ruta raíz del proyecto
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Preparar estructura de logs
$LogMessages = @()

# Variables globales para manejo de rutas
$BuildDir = $null
$PublicDir = $null
$zipPath = $null

# Función de logging con timestamp y persistencia
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $log = "$time [$Level] - $Message"
    Write-Host $log
    $script:LogMessages += $log
}

# Función para validar disponibilidad de .NET Framework
function Test-DotNetFramework {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        return $true
    }
    catch {
        return $false
    }
}

# Función para limpiar directorios de forma segura
function Remove-DirectorySafe {
    param([string]$Path)
    
    if ([string]::IsNullOrEmpty($Path)) {
        return
    }
    
    if (Test-Path $Path) {
        try {
            Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 100
        }
        catch {
            Write-Log -Message "ADVERTENCIA: No se pudo limpiar completamente: $Path" -Level "WARNING"
        }
    }
}

# NUEVA FUNCIÓN: Separar paquete en función y layer
function Split-LambdaPackage {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BuildDir,
        [Parameter(Mandatory=$true)]
        [string]$PublicDir,
        [Parameter(Mandatory=$true)]
        [string]$OriginalZipName
    )
    
    Write-Log -Message "SEPARACION: Iniciando separacion automatica en funcion y layer" -Level "INFO"
    
    # Inicializar variables para manejo de errores
    $LayerTempDir = $null
    $FunctionTempDir = $null
    
    try {
        # Crear directorios temporales
        $LayerTempDir = Join-Path -Path $PublicDir -ChildPath "layer-temp"
        $FunctionTempDir = Join-Path -Path $PublicDir -ChildPath "function-temp"
        
        # Limpiar si existen
        Remove-DirectorySafe -Path $LayerTempDir
        Remove-DirectorySafe -Path $FunctionTempDir
        
        # Crear directorios
        New-Item -ItemType Directory -Path $LayerTempDir -Force | Out-Null
        New-Item -ItemType Directory -Path $FunctionTempDir -Force | Out-Null
        
        # Crear estructura correcta para layer
        $LayerPythonDir = Join-Path -Path $LayerTempDir -ChildPath "python"
        $LayerLibDir = Join-Path -Path $LayerPythonDir -ChildPath "lib"
        $LayerSitePackagesDir = Join-Path -Path $LayerLibDir -ChildPath "python3.9"
        $LayerSitePackagesDir = Join-Path -Path $LayerSitePackagesDir -ChildPath "site-packages"
        
        New-Item -ItemType Directory -Path $LayerSitePackagesDir -Force | Out-Null
        
        # Patrones de dependencias que van al layer
        $dependencyPatterns = @(
            'pandas*', 'numpy*', 'boto3*', 'botocore*', 'requests*',
            'pydantic*', 'openpyxl*', 'urllib3*', 's3transfer*',
            'python_dateutil*', 'pytz*', 'six*', 'certifi*',
            'jmespath*', 'et_xmlfile*', 'typing_extensions*',
            'charset_normalizer*', 'idna*', 'xlsxwriter*'
        )
        
        # Obtener contenido del directorio build
        $buildItems = Get-ChildItem -Path $BuildDir -ErrorAction SilentlyContinue
        $layerItemCount = 0
        $functionItemCount = 0
        
        if ($buildItems) {
            foreach ($item in $buildItems) {
                if ($item -and $item.Name) {
                    $isLayerItem = $false
                    
                    # Verificar si es una dependencia
                    foreach ($pattern in $dependencyPatterns) {
                        if ($item.Name -like $pattern) {
                            $isLayerItem = $true
                            break
                        }
                    }
                    
                    # Verificar si es un directorio de dependencia típico
                    if (-not $isLayerItem -and $item.PSIsContainer) {
                        $name = $item.Name.ToLower()
                        if ($name -match '.*\.dist-info$' -or $name -match '.*\.egg-info$' -or 
                            $name -match '^_.*' -or $name -match '.*-.*-.*' -or
                            ($name.Length -gt 10 -and $name -notmatch '^[a-z][a-z0-9_]*$')) {
                            $isLayerItem = $true
                        }
                    }
                    
                    try {
                        if ($isLayerItem) {
                            # Copiar al layer
                            $destPath = Join-Path -Path $LayerSitePackagesDir -ChildPath $item.Name
                            if ($item.PSIsContainer) {
                                Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
                            } else {
                                Copy-Item -Path $item.FullName -Destination $destPath -Force
                            }
                            $layerItemCount++
                        } else {
                            # Copiar a la función
                            $destPath = Join-Path -Path $FunctionTempDir -ChildPath $item.Name
                            if ($item.PSIsContainer) {
                                Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
                            } else {
                                Copy-Item -Path $item.FullName -Destination $destPath -Force
                            }
                            $functionItemCount++
                        }
                    }
                    catch {
                        Write-Log -Message "ADVERTENCIA: No se pudo procesar item: $($item.Name)" -Level "WARNING"
                    }
                }
            }
        }
        
        Write-Log -Message "SEPARACION: $layerItemCount items para layer, $functionItemCount items para funcion" -Level "INFO"
        
        # Verificar que tenemos contenido
        if ($layerItemCount -eq 0 -and $functionItemCount -eq 0) {
            throw "No se encontro contenido para separar"
        }
        
        # Crear ZIPs
        $functionZipName = "function.zip"
        $layerZipName = "dependencies-layer.zip"
        
        $functionZipPath = Join-Path -Path $PublicDir -ChildPath $functionZipName
        $layerZipPath = Join-Path -Path $PublicDir -ChildPath $layerZipName
        
        # Crear ZIP de función
        if ($functionItemCount -gt 0) {
            try {
                [System.IO.Compression.ZipFile]::CreateFromDirectory(
                    $FunctionTempDir,
                    $functionZipPath,
                    [System.IO.Compression.CompressionLevel]::Optimal,
                    $false
                )
                Write-Log -Message "SEPARACION: function.zip creado exitosamente" -Level "INFO"
            }
            catch {
                Write-Log -Message "ERROR: No se pudo crear function.zip: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log -Message "ADVERTENCIA: No hay contenido para function.zip" -Level "WARNING"
        }
        
        # Crear ZIP de layer
        if ($layerItemCount -gt 0) {
            try {
                [System.IO.Compression.ZipFile]::CreateFromDirectory(
                    $LayerTempDir,
                    $layerZipPath,
                    [System.IO.Compression.CompressionLevel]::Optimal,
                    $false
                )
                Write-Log -Message "SEPARACION: dependencies-layer.zip creado exitosamente" -Level "INFO"
            }
            catch {
                Write-Log -Message "ERROR: No se pudo crear dependencies-layer.zip: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log -Message "ADVERTENCIA: No hay contenido para dependencies-layer.zip" -Level "WARNING"
        }
        
        # Obtener tamaños
        $functionSizeMB = 0.0
        $layerSizeMB = 0.0
        
        if (Test-Path $functionZipPath) {
            $functionInfo = Get-Item -Path $functionZipPath
            $functionSizeMB = [Math]::Round(($functionInfo.Length / 1MB), 1)
        }
        
        if (Test-Path $layerZipPath) {
            $layerInfo = Get-Item -Path $layerZipPath
            $layerSizeMB = [Math]::Round(($layerInfo.Length / 1MB), 1)
        }
        
        # Limpiar directorios temporales
        Remove-DirectorySafe -Path $LayerTempDir
        Remove-DirectorySafe -Path $FunctionTempDir
        
        # Verificar que al menos uno de los ZIPs se creó correctamente
        $functionExists = Test-Path $functionZipPath
        $layerExists = Test-Path $layerZipPath
        
        if (-not $functionExists -and -not $layerExists) {
            throw "No se pudo crear ninguno de los archivos ZIP"
        }
        
        return @{
            Success = $true
            FunctionZip = $functionZipPath
            LayerZip = $layerZipPath
            FunctionSizeMB = $functionSizeMB
            LayerSizeMB = $layerSizeMB
        }
    }
    catch {
        Write-Log -Message "ERROR: Error en separacion: $($_.Exception.Message)" -Level "ERROR"
        
        # Limpiar en caso de error (solo si las variables están inicializadas)
        if (-not [string]::IsNullOrEmpty($LayerTempDir)) {
            Remove-DirectorySafe -Path $LayerTempDir
        }
        if (-not [string]::IsNullOrEmpty($FunctionTempDir)) {
            Remove-DirectorySafe -Path $FunctionTempDir
        }
        
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

# NUEVA FUNCIÓN: Generar instrucciones de deploy
function Generate-DeployInstructions {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PublicDir,
        [Parameter(Mandatory=$true)]
        [string]$FunctionZipName,
        [Parameter(Mandatory=$true)]
        [string]$LayerZipName,
        [Parameter(Mandatory=$true)]
        [decimal]$FunctionSizeMB,
        [Parameter(Mandatory=$true)]
        [decimal]$LayerSizeMB
    )
    
    $instructionsContent = @"
========================================
   INSTRUCCIONES DE DEPLOY - AWS LAMBDA
========================================

ARCHIVOS GENERADOS:
- $FunctionZipName ($FunctionSizeMB MB) - Código de tu aplicación  
- $LayerZipName ($LayerSizeMB MB) - Dependencias Python

========================================
OPCIÓN 1: CONSOLA AWS (Interfaz Web)
========================================

PASO 1: CREAR LAYER
-------------------
1. Ir a: https://console.aws.amazon.com/lambda/
2. En el menú izquierdo -> "Layers" 
3. Clic en "Create layer"
4. Completar formulario:
   * Name: mi-proyecto-dependencies
   * Description: Dependencias Python para mi proyecto
   * Upload: Seleccionar "$LayerZipName"
   * Compatible runtimes: Python 3.9, Python 3.10, Python 3.11
   * Compatible architectures: x86_64
5. Clic "Create"
6. COPIAR EL ARN que aparece (lo necesitarás en el paso 2)
   Ejemplo: arn:aws:lambda:us-east-1:123456789012:layer:mi-proyecto-dependencies:1

PASO 2: ACTUALIZAR FUNCIÓN LAMBDA
---------------------------------
1. Ir a: https://console.aws.amazon.com/lambda/
2. En "Functions" -> Seleccionar tu función
3. En la pestaña "Code":
   * Clic "Upload from" -> ".zip file"
   * Seleccionar "$FunctionZipName"
   * Clic "Save"
4. Bajar hasta la sección "Layers":
   * Clic "Add a layer"
   * Seleccionar "Custom layers"
   * Pegar el ARN del PASO 1
   * Version: 1
   * Clic "Add"
5. Deploy completado

========================================
OPCIÓN 2: AWS CLI (Línea de Comandos)
========================================

PASO 1: CREAR LAYER
-------------------
aws lambda publish-layer-version \
    --layer-name "mi-proyecto-dependencies" \
    --description "Dependencias Python para mi proyecto" \
    --zip-file fileb://$LayerZipName \
    --compatible-runtimes python3.9 python3.10 python3.11 \
    --compatible-architectures x86_64

PASO 2: ACTUALIZAR FUNCIÓN
--------------------------
# Actualizar código
aws lambda update-function-code \
    --function-name "TU_FUNCION_AQUI" \
    --zip-file fileb://$FunctionZipName

# Agregar layer (usar ARN del paso 1)
aws lambda update-function-configuration \
    --function-name "TU_FUNCION_AQUI" \
    --layers arn:aws:lambda:REGION:ACCOUNT:layer:mi-proyecto-dependencies:1

========================================
NOTAS IMPORTANTES
========================================

ACTUALIZACIONES FUTURAS:
- Cambios en código -> Solo subir $FunctionZipName (PASO 2)
- Cambios en dependencias -> Crear nueva versión del layer

LÍMITES AWS:
- Layer: 250MB descomprimido máximo
- Función + Layers: 250MB total descomprimido
- Máximo 5 layers por función

BENEFICIOS:
- Deploy de código 10x más rápido (solo $FunctionSizeMB MB vs 50+ MB)
- Layer reutilizable para múltiples funciones
- Versionado independiente de dependencias vs código

========================================
"@

    try {
        $instructionsPath = Join-Path -Path $PublicDir -ChildPath "deploy-instructions.txt"
        $instructionsContent | Out-File -FilePath $instructionsPath -Encoding UTF8
        Write-Log -Message "INSTRUCCIONES: Archivo generado en: deploy-instructions.txt" -Level "INFO"
        return $instructionsPath
    }
    catch {
        Write-Log -Message "ADVERTENCIA: No se pudo generar archivo de instrucciones: $($_.Exception.Message)" -Level "WARNING"
        return $null
    }
}

try {
    Write-Log -Message "INICIANDO: Preparacion del paquete Lambda" -Level "INFO"

    # Inicializar variables de rutas
    $BuildDir = Join-Path -Path $ProjectRoot -ChildPath 'build'
    $PublicDir = Join-Path -Path $ProjectRoot -ChildPath 'Publicar'

    # Validar .NET Framework
    if (-not (Test-DotNetFramework)) {
        throw ".NET Framework System.IO.Compression.FileSystem no esta disponible"
    }
    Write-Log -Message "VALIDACION: .NET Framework disponible" -Level "INFO"

    # 1. Limpiar carpetas previas
    Write-Log -Message "LIMPIEZA: Limpiando carpetas si existen" -Level "INFO"
    
    Remove-DirectorySafe -Path $BuildDir
    
    if (-not (Test-Path $PublicDir)) {
        New-Item -ItemType Directory -Path $PublicDir -Force | Out-Null
    }

    # 2. Crear carpetas necesarias
    Write-Log -Message "SETUP: Creando carpetas de trabajo" -Level "INFO"
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

    # 3. Instalar dependencias con manejo corregido del ErrorActionPreference
    $requirementsFile = Join-Path -Path $ProjectRoot -ChildPath 'requirements.txt'
    if (Test-Path $requirementsFile) {
        Write-Log -Message "DEPENDENCIAS: Instalando dependencias desde requirements.txt" -Level "INFO"
        
        # Cambiar temporalmente ErrorActionPreference para pip
        $originalErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        
        try {
            $pipCheck = pip --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Log -Message "DEPENDENCIAS: Ejecutando pip install" -Level "INFO"
                
                # Primera estrategia: instalación normal ignorando warnings
                pip install -r $requirementsFile -t $BuildDir --upgrade --force-reinstall --no-cache-dir --disable-pip-version-check 2>$null
                
                # Verificar si realmente se instalaron las dependencias
                $installedPackages = @()
                $buildDirs = Get-ChildItem -Path $BuildDir -Directory -ErrorAction SilentlyContinue
                if ($buildDirs) {
                    foreach ($dir in $buildDirs) {
                        if ($dir.Name -match '^(pandas|boto3|requests|pydantic|openpyxl)') {
                            $installedPackages += $dir
                        }
                    }
                }
                
                if ($installedPackages.Count -gt 0) {
                    Write-Log -Message "DEPENDENCIAS: Instalacion exitosa - Se detectaron $($installedPackages.Count) paquetes principales" -Level "INFO"
                    foreach ($pkg in $installedPackages) {
                        Write-Log -Message "  - $($pkg.Name) instalado" -Level "INFO"
                    }
                } else {
                    Write-Log -Message "DEPENDENCIAS: No se detectaron paquetes, intentando con --no-deps" -Level "WARNING"
                    
                    # Segunda estrategia: sin verificación de dependencias
                    pip install -r $requirementsFile -t $BuildDir --no-deps --force-reinstall --no-cache-dir --disable-pip-version-check 2>$null
                    
                    # Verificar nuevamente
                    $installedPackages2 = @()
                    $buildDirs2 = Get-ChildItem -Path $BuildDir -Directory -ErrorAction SilentlyContinue
                    if ($buildDirs2) {
                        foreach ($dir2 in $buildDirs2) {
                            if ($dir2.Name -match '^(pandas|boto3|requests|pydantic|openpyxl)') {
                                $installedPackages2 += $dir2
                            }
                        }
                    }
                    
                    if ($installedPackages2.Count -gt 0) {
                        Write-Log -Message "DEPENDENCIAS: Instalacion con --no-deps exitosa" -Level "INFO"
                    } else {
                        Write-Log -Message "DEPENDENCIAS: Instalacion linea por linea" -Level "WARNING"
                        
                        # Tercera estrategia: línea por línea
                        $requirements = Get-Content $requirementsFile | Where-Object { $_.Trim() -ne '' -and -not $_.StartsWith('#') }
                        $successCount = 0
                        
                        foreach ($requirement in $requirements) {
                            $requirement = $requirement.Trim()
                            if ($requirement -ne '') {
                                Write-Log -Message "  Instalando: $requirement" -Level "INFO"
                                pip install $requirement -t $BuildDir --no-deps --force-reinstall --no-cache-dir --disable-pip-version-check 2>$null
                                if ($LASTEXITCODE -eq 0) {
                                    $successCount++
                                    Write-Log -Message "    Exito: $requirement" -Level "INFO"
                                } else {
                                    Write-Log -Message "    Fallo: $requirement" -Level "WARNING"
                                }
                            }
                        }
                        
                        Write-Log -Message "DEPENDENCIAS: Se instalaron $successCount de $($requirements.Count) dependencias" -Level "INFO"
                    }
                }
                
                # Verificación final de dependencias instaladas
                $finalPackages = Get-ChildItem -Path $BuildDir -Directory -ErrorAction SilentlyContinue
                $dependencyCount = 0
                if ($finalPackages) {
                    $dependencyCount = $finalPackages.Count
                }
                Write-Log -Message "VERIFICACION: Total de $dependencyCount directorios de paquetes en build" -Level "INFO"
                
            } else {
                Write-Log -Message "ADVERTENCIA: pip no esta disponible en el sistema" -Level "WARNING"
            }
        }
        finally {
            # Restaurar ErrorActionPreference original
            $ErrorActionPreference = $originalErrorAction
        }
    } else {
        Write-Log -Message "ADVERTENCIA: requirements.txt no encontrado" -Level "WARNING"
    }

    # 4. Copiar código fuente con exclusiones AGRESIVAS
    Write-Log -Message "COPIA: Copiando archivos fuente con exclusiones agresivas" -Level "INFO"

    # Patrones de exclusión más agresivos
    $excludePatterns = @(
        # Entornos virtuales (CRÍTICO)
        [regex]::Escape('venv\'),
        [regex]::Escape('.venv\'),
        [regex]::Escape('env\'),
        [regex]::Escape('.env\'),
        [regex]::Escape('virtualenv\'),
        # Carpetas de desarrollo
        [regex]::Escape('tests\'),
        [regex]::Escape('test\'),
        [regex]::Escape('.git\'),
        [regex]::Escape('__pycache__\'),
        [regex]::Escape('docs\'),
        [regex]::Escape('doc\'),
        [regex]::Escape('examples\'),
        [regex]::Escape('example\'),
        [regex]::Escape('testdata\'),
        [regex]::Escape('build\'),
        [regex]::Escape('Publicar\'),
        [regex]::Escape('.pytest_cache\'),
        [regex]::Escape('.vscode\'),
        [regex]::Escape('.idea\'),
        [regex]::Escape('node_modules\'),
        [regex]::Escape('\.dist-info\'),
        [regex]::Escape('\.egg-info\'),
        [regex]::Escape('\bin\'),
        [regex]::Escape('\Scripts\'),
        [regex]::Escape('\include\'),
        [regex]::Escape('\share\'),
        [regex]::Escape('\benchmark'),
        [regex]::Escape('\sample'),
        [regex]::Escape('\demo'),
        [regex]::Escape('\tutorial')
    )
    
    # Extensiones excluidas agresivas (INCLUYE .ps1 EXPLÍCITAMENTE)
    $excludeExtensions = @(
        '*.log', '*.md', '*.tmp', '*.pyc', '*.pyo', '*.pyd', 
        '.DS_Store', '*.txt', '*.rst', '*.yml', '*.yaml',
        '*.json', '*.xml', '*.cfg', '*.ini', '*.conf',
        '*.exe', '*.dll', '*.so', '*.dylib', '*.a', '*.lib',
        '*.jpg', '*.jpeg', '*.png', '*.gif', '*.bmp', '*.ico', '*.svg',
        '*.pdf', '*.doc', '*.docx', '*.xls', '*.xlsx', '*.ppt', '*.pptx',
        '*.zip', '*.tar', '*.gz', '*.bz2', '*.rar', '*.7z',
        '*.c', '*.cpp', '*.h', '*.hpp', '*.java', '*.class', '*.jar',
        '*.ps1', '*.bat', '*.cmd', '*.sh', '*.bash',
        'requirements*.txt', 'setup.py', 'setup.cfg', 'MANIFEST.in',
        'Makefile', 'CMakeLists.txt', 'Dockerfile*',
        'LICENSE*', 'COPYING*', 'COPYRIGHT*', 'NOTICE*', 'AUTHORS*',
        'CHANGELOG*', 'CHANGES*', 'HISTORY*', 'NEWS*', 'README*',
        '.env*', '.environment*'
    )

    # Procesar archivos
    $sourceFiles = Get-ChildItem -Path $ProjectRoot -Recurse -File -ErrorAction SilentlyContinue
    $copiedCount = 0
    $skippedCount = 0
    $totalSizeBytes = 0
    $excludedVenvFiles = 0
    
    foreach ($file in $sourceFiles) {
        $shouldInclude = $true
        $relativePath = $file.FullName.Replace($ProjectRoot, '')
        $fileName = $file.Name
        
        # Verificar extensiones excluidas
        foreach ($pattern in $excludeExtensions) {
            if ($fileName -like $pattern) {
                $shouldInclude = $false
                $skippedCount++
                break
            }
        }
        
        # Verificar patrones de rutas si no fue excluido por extensión
        if ($shouldInclude) {
            foreach ($pattern in $excludePatterns) {
                if ($relativePath -match $pattern) {
                    $shouldInclude = $false
                    $skippedCount++
                    
                    # Contar archivos de venv
                    if ($pattern -match 'venv|\.venv|env|\.env') {
                        $excludedVenvFiles++
                    }
                    break
                }
            }
        }
        
        # Excluir archivos grandes (>5MB)
        if ($shouldInclude -and $file.Length -gt 5MB) {
            $fileSizeMB = [Math]::Round($file.Length / 1MB, 2)
            Write-Log -Message "EXCLUSION: Archivo grande excluido: $fileName ($fileSizeMB MB)" -Level "INFO"
            $shouldInclude = $false
            $skippedCount++
        }
        
        # Copiar archivo si debe incluirse
        if ($shouldInclude) {
            try {
                $relativePathClean = $relativePath.TrimStart('\')
                $destPath = Join-Path -Path $BuildDir -ChildPath $relativePathClean
                $destDir = Split-Path -Path $destPath -Parent
                
                if (-not (Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                
                Copy-Item -Path $file.FullName -Destination $destPath -Force
                $copiedCount++
                $totalSizeBytes += $file.Length
            }
            catch {
                Write-Log -Message "ADVERTENCIA: No se pudo copiar: $fileName" -Level "WARNING"
            }
        }
    }

    $totalSizeMB = [Math]::Round($totalSizeBytes / 1MB, 2)
    Write-Log -Message "COPIA: Se copiaron $copiedCount archivos ($totalSizeMB MB), se excluyeron $skippedCount" -Level "INFO"
    
    if ($excludedVenvFiles -gt 0) {
        Write-Log -Message "EXCLUSION: Se excluyeron $excludedVenvFiles archivos de entornos virtuales" -Level "INFO"
    }

    # 5. Optimizar dependencias pesadas instaladas (con validaciones de Path null)
    Write-Log -Message "OPTIMIZACION: Optimizando dependencias pesadas para AWS Lambda" -Level "INFO"
    
    # Verificar que BuildDir existe antes de optimizar
    if (-not (Test-Path $BuildDir)) {
        Write-Log -Message "ADVERTENCIA: BuildDir no existe, saltando optimizacion" -Level "WARNING"
    } else {
        # Optimizar pandas
        $pandasDirs = Get-ChildItem -Path $BuildDir -Directory -Name "pandas*" -ErrorAction SilentlyContinue
        if ($pandasDirs) {
            foreach ($pandasDirName in $pandasDirs) {
                if (-not [string]::IsNullOrEmpty($pandasDirName)) {
                    $pandasPath = Join-Path -Path $BuildDir -ChildPath $pandasDirName
                    
                    if (Test-Path $pandasPath) {
                        # Remover directorios de testing de pandas
                        $testDirs = @('tests', 'test', '_testing', 'conftest')
                        foreach ($testDir in $testDirs) {
                            if (-not [string]::IsNullOrEmpty($testDir)) {
                                $testPath = Join-Path -Path $pandasPath -ChildPath $testDir
                                if (Test-Path $testPath) {
                                    Remove-Item -Recurse -Force $testPath -ErrorAction SilentlyContinue
                                    Write-Log -Message "OPTIMIZACION: Removido $testDir de pandas" -Level "INFO"
                                }
                            }
                        }
                        
                        # Remover archivos .pyx y .pxd
                        $pyxFiles = Get-ChildItem -Path $pandasPath -Recurse -Filter "*.pyx" -ErrorAction SilentlyContinue
                        if ($pyxFiles) {
                            foreach ($pyxFile in $pyxFiles) {
                                if ($pyxFile -and $pyxFile.FullName) {
                                    Remove-Item -Force $pyxFile.FullName -ErrorAction SilentlyContinue
                                }
                            }
                        }
                        
                        $pxdFiles = Get-ChildItem -Path $pandasPath -Recurse -Filter "*.pxd" -ErrorAction SilentlyContinue
                        if ($pxdFiles) {
                            foreach ($pxdFile in $pxdFiles) {
                                if ($pxdFile -and $pxdFile.FullName) {
                                    Remove-Item -Force $pxdFile.FullName -ErrorAction SilentlyContinue
                                }
                            }
                        }
                    }
                }
            }
        }
        
        # Optimizar numpy
        $numpyDirs = Get-ChildItem -Path $BuildDir -Directory -Name "numpy*" -ErrorAction SilentlyContinue
        if ($numpyDirs) {
            foreach ($numpyDirName in $numpyDirs) {
                if (-not [string]::IsNullOrEmpty($numpyDirName)) {
                    $numpyPath = Join-Path -Path $BuildDir -ChildPath $numpyDirName
                    
                    if (Test-Path $numpyPath) {
                        $testsPath = Join-Path -Path $numpyPath -ChildPath "tests"
                        if (Test-Path $testsPath) {
                            Remove-Item -Recurse -Force $testsPath -ErrorAction SilentlyContinue
                            Write-Log -Message "OPTIMIZACION: Removido tests de numpy" -Level "INFO"
                        }
                    }
                }
            }
        }
        
        # Optimizar boto3 y botocore
        $botoDirs = Get-ChildItem -Path $BuildDir -Directory -Name "boto*" -ErrorAction SilentlyContinue
        if ($botoDirs) {
            foreach ($botoDirName in $botoDirs) {
                if (-not [string]::IsNullOrEmpty($botoDirName)) {
                    $botoPath = Join-Path -Path $BuildDir -ChildPath $botoDirName
                    
                    if (Test-Path $botoPath) {
                        $dataPath = Join-Path -Path $botoPath -ChildPath "data"
                        
                        if (Test-Path $dataPath) {
                            $essentialServices = @('lambda', 's3', 'dynamodb', 'ec2', 'iam', 'cloudformation')
                            $allServices = Get-ChildItem -Path $dataPath -Directory -ErrorAction SilentlyContinue
                            
                            if ($allServices) {
                                foreach ($service in $allServices) {
                                    if ($service -and $service.Name -and $service.FullName) {
                                        $isEssential = $false
                                        foreach ($essential in $essentialServices) {
                                            if ($service.Name -eq $essential) {
                                                $isEssential = $true
                                                break
                                            }
                                        }
                                        
                                        if (-not $isEssential) {
                                            Remove-Item -Recurse -Force $service.FullName -ErrorAction SilentlyContinue
                                        }
                                    }
                                }
                            }
                            Write-Log -Message "OPTIMIZACION: Optimizado servicios de $botoDirName" -Level "INFO"
                        }
                    }
                }
            }
        }
        
        # Remover metadatos de paquetes
        $distInfoDirs = Get-ChildItem -Path $BuildDir -Directory -Name "*.dist-info" -ErrorAction SilentlyContinue
        if ($distInfoDirs) {
            foreach ($distInfo in $distInfoDirs) {
                if ($distInfo -and $distInfo.FullName) {
                    Remove-Item -Recurse -Force $distInfo.FullName -ErrorAction SilentlyContinue
                }
            }
        }
        
        # Remover cache residual
        $pycacheDirs = Get-ChildItem -Path $BuildDir -Directory -Name "__pycache__" -Recurse -ErrorAction SilentlyContinue
        if ($pycacheDirs) {
            foreach ($pycache in $pycacheDirs) {
                if ($pycache -and $pycache.FullName) {
                    Remove-Item -Recurse -Force $pycache.FullName -ErrorAction SilentlyContinue
                }
            }
        }
    }
    
    Write-Log -Message "OPTIMIZACION: Optimizacion de dependencias completada" -Level "INFO"

    # 6. Verificar archivos finales en build antes de crear ZIP
    $buildFiles = Get-ChildItem -Path $BuildDir -Recurse -File -ErrorAction SilentlyContinue
    $totalFileCount = 0
    if ($buildFiles) {
        $totalFileCount = $buildFiles.Count
    }
    
    Write-Log -Message "CONTEO: Se empaquetaran $totalFileCount archivos en total (post-optimizacion)" -Level "INFO"
    
    if ($totalFileCount -eq 0) {
        Write-Log -Message "ERROR: No se encontraron archivos para empaquetar" -Level "ERROR"
        Write-Log -Message "POSIBLES CAUSAS:" -Level "ERROR"
        Write-Log -Message "1. No se instalaron dependencias por conflictos de pip" -Level "ERROR"
        Write-Log -Message "2. Todos los archivos del proyecto fueron excluidos" -Level "ERROR"
        Write-Log -Message "3. Error en la copia de archivos fuente" -Level "ERROR"
        throw "No hay contenido valido para crear el paquete Lambda"
    }
    
    # Verificar que al menos tenemos algunos archivos .py
    $pythonFiles = Get-ChildItem -Path $BuildDir -Recurse -Filter "*.py" -ErrorAction SilentlyContinue
    if (-not $pythonFiles -or $pythonFiles.Count -eq 0) {
        Write-Log -Message "ADVERTENCIA: No se encontraron archivos Python (.py) en el paquete" -Level "WARNING"
        Write-Log -Message "Verifique que su codigo fuente este siendo copiado correctamente" -Level "WARNING"
    } else {
        Write-Log -Message "VERIFICACION: Se encontraron $($pythonFiles.Count) archivos Python" -Level "INFO"
    }

    # 7. Crear ZIP con validaciones adicionales
    Write-Log -Message "COMPRESION: Empaquetando ZIP con compresion Optimal" -Level "INFO"
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $folderName = Split-Path -Path $ProjectRoot -Leaf
    $zipFileName = "${folderName}_${timestamp}.zip"
    $zipPath = Join-Path -Path $PublicDir -ChildPath $zipFileName

    # Verificar que el directorio PublicDir existe
    if (-not (Test-Path $PublicDir)) {
        New-Item -ItemType Directory -Path $PublicDir -Force | Out-Null
    }

    # Verificar que BuildDir tiene contenido válido antes de crear ZIP
    if (-not (Test-Path $BuildDir)) {
        throw "El directorio de build no existe: $BuildDir"
    }
    
    $buildContent = Get-ChildItem -Path $BuildDir -ErrorAction SilentlyContinue
    if (-not $buildContent -or $buildContent.Count -eq 0) {
        throw "El directorio de build esta vacio: $BuildDir"
    }

    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $BuildDir,
            $zipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false
        )
        
        Write-Log -Message "EXITO: ZIP creado en: $zipPath" -Level "SUCCESS"
    }
    catch {
        Write-Log -Message "ERROR: No se pudo crear el ZIP: $($_.Exception.Message)" -Level "ERROR"
        throw "Fallo en la creacion del archivo ZIP"
    }

    # 8. Validar ZIP
    Write-Log -Message "VALIDACION: Validando integridad del ZIP" -Level "INFO"
    
    if (-not (Test-Path $zipPath)) {
        throw "El archivo ZIP no fue creado correctamente: $zipPath"
    }
    
    try {
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entryCount = $zipArchive.Entries.Count
        $zipArchive.Dispose()
        
        if ($entryCount -gt 0) {
            Write-Log -Message "EXITO: ZIP contiene $entryCount entradas" -Level "SUCCESS"
        } else {
            throw "El ZIP esta vacio"
        }
    }
    catch {
        Write-Log -Message "ERROR: Error en validacion del ZIP: $($_.Exception.Message)" -Level "ERROR"
        throw "ZIP no valido: $($_.Exception.Message)"
    }

    # 9. Verificar tamaño y aplicar separación automática si es necesario
    if (-not (Test-Path $zipPath)) {
        throw "No se puede verificar el tamaño: el archivo ZIP no existe"
    }
    
    $zipInfo = Get-Item -Path $zipPath
    $zipSizeMB = [Math]::Round($zipInfo.Length / 1MB, 2)
    
    Write-Log -Message "TAMANO: ZIP final de $zipSizeMB MB" -Level "INFO"
    
    if ($zipSizeMB -gt 50) {
        Write-Log -Message "ACTIVANDO: Separacion automatica por tamaño ($zipSizeMB MB)" -Level "INFO"
        
        # Llamar función de separación
        $splitResult = Split-LambdaPackage -BuildDir $BuildDir -PublicDir $PublicDir -OriginalZipName $zipFileName
        
        if ($splitResult.Success) {
            Write-Log -Message "EXITO: Paquetes separados creados exitosamente" -Level "SUCCESS"
            Write-Log -Message "FUNCION: function.zip ($($splitResult.FunctionSizeMB) MB)" -Level "INFO"
            Write-Log -Message "LAYER: dependencies-layer.zip ($($splitResult.LayerSizeMB) MB)" -Level "INFO"
            
            # Generar instrucciones
            $instructionsPath = Generate-DeployInstructions -PublicDir $PublicDir -FunctionZipName "function.zip" -LayerZipName "dependencies-layer.zip" -FunctionSizeMB $splitResult.FunctionSizeMB -LayerSizeMB $splitResult.LayerSizeMB
            
            if ($instructionsPath) {
                Write-Log -Message "EXITO: Instrucciones generadas en: deploy-instructions.txt" -Level "SUCCESS"
            }
            
            Write-Log -Message "========================================" -Level "INFO"
            Write-Log -Message "RESULTADO: Separacion automatica completada" -Level "SUCCESS"
            Write-Log -Message "- function.zip ($($splitResult.FunctionSizeMB) MB) - Tu codigo de aplicacion" -Level "INFO"
            Write-Log -Message "- dependencies-layer.zip ($($splitResult.LayerSizeMB) MB) - Dependencias Python" -Level "INFO"
            Write-Log -Message "- deploy-instructions.txt - Instrucciones completas" -Level "INFO"
            Write-Log -Message "- $zipFileName ($zipSizeMB MB) - Paquete original (referencia)" -Level "INFO"
            Write-Log -Message "========================================" -Level "INFO"
            Write-Log -Message "SIGUIENTE PASO: Revisar deploy-instructions.txt para subir a AWS" -Level "SUCCESS"
            
        } else {
            Write-Log -Message "ERROR: Fallo en separacion automatica: $($splitResult.Error)" -Level "ERROR"
            Write-Log -Message "FALLBACK: Usando recomendaciones tradicionales" -Level "WARNING"
            
            # Mostrar recomendaciones tradicionales
            Write-Log -Message "PROBLEMA: ZIP supera 50MB ($zipSizeMB MB) - Limite de AWS Lambda Console" -Level "WARNING"
            Write-Log -Message "========================================" -Level "WARNING"
            Write-Log -Message "SOLUCIONES RECOMENDADAS:" -Level "WARNING"
            Write-Log -Message "" -Level "INFO"
            Write-Log -Message "OPCION 1 - AWS CLI (MAS FACIL):" -Level "WARNING"
            Write-Log -Message "aws lambda update-function-code --function-name TU_FUNCION --zip-file fileb://$zipPath" -Level "WARNING"
            Write-Log -Message "" -Level "INFO"
            Write-Log -Message "OPCION 2 - AWS LAMBDA LAYERS:" -Level "WARNING"
            Write-Log -Message "Crear un layer separado con pandas y boto3:" -Level "WARNING"
            Write-Log -Message "1. Crear requirements-layer.txt con: pandas>=2.2.2 y boto3>=1.34.0" -Level "WARNING"
            Write-Log -Message "2. Crear requirements-function.txt con: requests, pydantic, openpyxl" -Level "WARNING"
            Write-Log -Message "3. El layer manejara las dependencias pesadas" -Level "WARNING"
            Write-Log -Message "" -Level "INFO"
            Write-Log -Message "OPCION 3 - CONTENEDOR DOCKER:" -Level "WARNING"
            Write-Log -Message "Para proyectos grandes, usar Amazon ECR + contenedores" -Level "WARNING"
            Write-Log -Message "Limite: 10GB (imagen de contenedor)" -Level "WARNING"
            Write-Log -Message "========================================" -Level "WARNING"
        }
    } elseif ($zipSizeMB -gt 45) {
        Write-Log -Message "ATENCION: ZIP cerca del limite (50MB) - $zipSizeMB MB" -Level "WARNING"
        Write-Log -Message "Considere usar AWS CLI o Lambda Layers para futuras expansiones" -Level "WARNING"
    } else {
        Write-Log -Message "EXITO: ZIP de $zipSizeMB MB - OK para carga directa en consola AWS" -Level "SUCCESS"
    }

    # 10. Limpieza
    Remove-DirectorySafe -Path $BuildDir
    Write-Log -Message "LIMPIEZA: Carpeta build eliminada" -Level "INFO"

    Write-Log -Message "COMPLETADO: Paquete listo para AWS Lambda" -Level "INFO"
    Write-Log -Message "UBICACION: $zipPath" -Level "INFO"

    # 11. Guardar log
    if ([string]::IsNullOrEmpty($zipFileName)) {
        $logFileName = "lambda_package_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    } else {
        $logFileName = $zipFileName -replace '\.zip$', '.log'
    }
    
    $logPath = Join-Path -Path $PublicDir -ChildPath $logFileName
    $LogMessages | Out-File -FilePath $logPath -Encoding UTF8
    Write-Log -Message "LOG: Log guardado en: $logPath" -Level "INFO"

}
catch {
    $errorMessage = $_.Exception.Message
    Write-Log -Message "ERROR: Error durante la ejecucion: $errorMessage" -Level "ERROR"
    
    # Limpiar en caso de error
    Remove-DirectorySafe -Path $BuildDir
    
    # Guardar log de error
    try {
        if (-not (Test-Path $PublicDir)) {
            New-Item -ItemType Directory -Path $PublicDir -Force | Out-Null
        }
        
        $errorTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $errorLogPath = Join-Path -Path $PublicDir -ChildPath "error_${errorTimestamp}.log"
        
        if ($LogMessages -and $LogMessages.Count -gt 0) {
            $LogMessages | Out-File -FilePath $errorLogPath -Encoding UTF8
            Write-Host "LOG ERROR: Log de error guardado en: $errorLogPath"
        } else {
            "Error durante la ejecucion: $errorMessage" | Out-File -FilePath $errorLogPath -Encoding UTF8
            Write-Host "LOG ERROR: Log basico de error guardado en: $errorLogPath"
        }
    }
    catch {
        Write-Host "ERROR CRITICO: No se pudo guardar log de error: $($_.Exception.Message)"
    }
    
    exit 1
}