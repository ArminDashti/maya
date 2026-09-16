# Sync Maya models, RAG, skills, users (wrapper).
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\.armin\rag\sync-maya.ps1') @args
