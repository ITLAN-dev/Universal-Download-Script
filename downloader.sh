#!/bin/bash

# =================================================
# Universal Download Script with Resume Support
# Usage: ./download.sh [OPTIONS] URL...
# MIT License - see LICENSE.md for details 
# ITLAN (c) 2026 
# =================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Функция получения размера файла из заголовков (без скачивания)
get_remote_size() {
    local url=$1
    local size=0
    
    # Пробуем curl
    if command -v curl &> /dev/null; then
        size=$(curl -sI "$url" | grep -i content-length | awk '{print $2}' | tr -d '\r')
    # Пробуем wget
    elif command -v wget &> /dev/null; then
        size=$(wget --spider --server-response "$url" 2>&1 | grep -i content-length | tail -1 | awk '{print $2}' | tr -d '\r')
    fi
    
    echo "$size"
}

# Функция форматирования размера
format_size() {
    local size=$1
    if [ $size -ge 1073741824 ]; then
        echo "$(echo "scale=2; $size/1073741824" | bc) GB"
    elif [ $size -ge 1048576 ]; then
        echo "$(echo "scale=2; $size/1048576" | bc) MB"
    elif [ $size -ge 1024 ]; then
        echo "$(echo "scale=2; $size/1024" | bc) KB"
    else
        echo "${size} B"
    fi
}

# Функция проверки файла
check_file() {
    local file=$1
    local url=$2
    local min_size=$3
    
    if [ ! -f "$file" ]; then
        echo "missing"
        return
    fi
    
    local local_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    
    # Если файл слишком маленький - поврежден
    if [ $local_size -lt $min_size ]; then
        echo "corrupt"
        return
    fi
    
    # Получаем размер на сервере
    local remote_size=$(get_remote_size "$url")
    
    # Если не удалось получить размер с сервера, считаем по минимальному размеру
    if [ -z "$remote_size" ] || [ "$remote_size" -eq 0 ]; then
        echo "valid"
        return
    fi
    
    # Сравниваем размеры
    if [ $local_size -eq $remote_size ]; then
        echo "complete"
    elif [ $local_size -lt $remote_size ]; then
        echo "partial"
    else
        echo "invalid"
    fi
}

# Функция загрузки с докачкой
download_with_resume() {
    local url=$1
    local output=$2
    local min_size=$3
    
    local filename=$(basename "$output")
    local dir=$(dirname "$output")
    
    # Проверяем статус файла
    local status=$(check_file "$output" "$url" "$min_size")
    
    case $status in
        "complete")
            local size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
            echo -e "${GREEN}✅ Файл полностью загружен (размер: $(format_size $size))${NC}"
            return 0
            ;;
        "partial")
            local local_size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
            local remote_size=$(get_remote_size "$url")
            echo -e "${YELLOW}⏳ Файл загружен частично: $(format_size $local_size) из $(format_size $remote_size)${NC}"
            echo -e "${CYAN}🔄 Пробуем докачать...${NC}"
            ;;
        "corrupt")
            echo -e "${RED}❌ Файл поврежден (слишком маленький)${NC}"
            echo -e "${YELLOW}🗑️ Удаляем и качаем заново...${NC}"
            rm -f "$output"
            rm -f "${output}.aria2" 2>/dev/null
            ;;
        "invalid")
            echo -e "${RED}❌ Файл больше чем на сервере (ошибка)${NC}"
            echo -e "${YELLOW}🗑️ Удаляем и качаем заново...${NC}"
            rm -f "$output"
            rm -f "${output}.aria2" 2>/dev/null
            ;;
        "missing")
            echo -e "${CYAN}🔄 Файл не найден, начинаем загрузку...${NC}"
            ;;
    esac
    
    # Пробуем curl с докачкой
    if command -v curl &> /dev/null; then
        echo -e "${PURPLE}📥 curl: ${filename}${NC}"
        
        # Получаем размер для прогресса
        local remote_size=$(get_remote_size "$url")
        if [ -n "$remote_size" ] && [ "$remote_size" -gt 0 ]; then
            curl -# -L -C - --retry 3 --connect-timeout 30 -o "$output" "$url"
        else
            curl -# -L -C - --retry 3 --connect-timeout 30 -o "$output" "$url"
        fi
        
        local exit_code=$?
        if [ $exit_code -eq 0 ] || [ $exit_code -eq 18 ]; then  # 18 = partial file
            # Проверяем результат
            sleep 2  # Даем время на запись
            local status=$(check_file "$output" "$url" "$min_size")
            if [ "$status" = "complete" ] || [ "$status" = "valid" ]; then
                return 0
            fi
        fi
    fi
    
    # Пробуем wget с докачкой
    if command -v wget &> /dev/null; then
        echo -e "${PURPLE}📥 wget: ${filename}${NC}"
        wget -q --show-progress --progress=bar:force --timeout=30 --tries=3 -c -O "$output" "$url"
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            sleep 2
            local status=$(check_file "$output" "$url" "$min_size")
            if [ "$status" = "complete" ] || [ "$status" = "valid" ]; then
                return 0
            fi
        fi
    fi
    
    # Пробуем aria2c (лучшая поддержка докачки)
    if command -v aria2c &> /dev/null; then
        echo -e "${PURPLE}📥 aria2c: ${filename}${NC}"
        aria2c --console-log-level=notice --summary-interval=1 \
               --continue=true \
               -x 4 -s 4 --timeout=30 --connect-timeout=15 \
               -d "$dir" -o "$(basename "$output")" "$url"
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            sleep 2
            local status=$(check_file "$output" "$url" "$min_size")
            if [ "$status" = "complete" ] || [ "$status" = "valid" ]; then
                return 0
            fi
        fi
    fi
    
    return 1
}

# Функция загрузки одного файла
download_single_file() {
    local url=$1
    local output_dir=$2
    local min_size=${3:-1000000}
    local filename=$(basename "$url" | cut -d '?' -f1 | sed 's/%2F/\//g' | sed 's/%20/ /g')
    local output="${output_dir}/${filename}"
    local max_retries=5
    local retry_count=0
    
    echo -e "\n${BLUE}═══════════════════════════════════════════${NC}"
    echo -e "${BLUE}📦 Файл: ${filename}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
    
    # Создаем директорию если нужно
    mkdir -p "$output_dir"
    
    # Получаем размер на сервере для информации
    local remote_size=$(get_remote_size "$url")
    if [ -n "$remote_size" ] && [ "$remote_size" -gt 0 ]; then
        echo -e "${CYAN}Размер на сервере: $(format_size $remote_size)${NC}"
    fi
    
    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            echo -e "${YELLOW}🔄 Попытка $((retry_count+1))/$max_retries${NC}"
        fi
        
        if download_with_resume "$url" "$output" "$min_size"; then
            local final_size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
            echo -e "${GREEN}✅ Успешно загружен! (размер: $(format_size $final_size))${NC}"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            local wait_time=$((retry_count * 5))
            echo -e "${YELLOW}⏳ Ошибка, ждем ${wait_time}с...${NC}"
            sleep $wait_time
        fi
    done
    
    echo -e "${RED}❌ Не удалось загрузить ${filename} после $max_retries попыток${NC}"
    return 1
}

# Функция загрузки по паттерну
download_by_pattern() {
    local url_prefix=$1
    local start=$2
    local end=$3
    local output_dir=$4
    local file_ext=${5:-tar.gz}
    local min_size=${6:-1000000}
    
    mkdir -p "$output_dir"
    
    echo "========================================="
    echo "📋 Загрузка по паттерну"
    echo "========================================="
    echo "URL префикс: $url_prefix"
    echo "Диапазон: $start - $end"
    echo "Расширение: $file_ext"
    echo "Директория: $output_dir"
    echo "========================================="
    
    local total=$((end - start + 1))
    local current=0
    local success=0
    local failed=0
    
    for i in $(seq $start $end); do
        current=$((current + 1))
        echo -e "\n${BLUE}[$current/$total]${NC} Файл patch${i}.${file_ext}"
        
        local url="${url_prefix}patch${i}.${file_ext}"
        
        if download_single_file "$url" "$output_dir" "$min_size"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
        
        # Небольшая пауза между загрузками
        sleep 1
    done
    
    echo "========================================="
    echo -e "${GREEN}✅ Успешно: $success${NC}, ${RED}❌ Ошибок: $failed${NC}"
    echo "========================================="
}

# Функция загрузки из файла со списком URL
download_from_file() {
    local url_file=$1
    local output_dir=$2
    local min_size=${3:-1000000}
    
    if [ ! -f "$url_file" ]; then
        echo -e "${RED}❌ Файл $url_file не найден${NC}"
        return 1
    fi
    
    mkdir -p "$output_dir"
    
    # Подсчитываем количество URL
    local total=$(grep -v '^[[:space:]]*$' "$url_file" | grep -v '^#' | wc -l)
    local current=0
    local success=0
    local failed=0
    
    echo "========================================="
    echo "📋 Загрузка из файла: $url_file"
    echo "Всего URL: $total"
    echo "Директория: $output_dir"
    echo "========================================="
    
    while IFS= read -r url || [ -n "$url" ]; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]] && continue
        
        current=$((current + 1))
        echo -e "\n${BLUE}[$current/$total]${NC} URL: $url"
        
        if download_single_file "$url" "$output_dir" "$min_size"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
        
        sleep 1
    done < <(grep -v '^#' "$url_file" | grep -v '^[[:space:]]*$')
    
    echo "========================================="
    echo -e "${GREEN}✅ Успешно: $success${NC}, ${RED}❌ Ошибок: $failed${NC}"
    echo "========================================="
}

# Функция загрузки одного URL
download_single_url() {
    local url=$1
    local output_dir=$2
    local min_size=${3:-1000000}
    
    mkdir -p "$output_dir"
    
    echo "========================================="
    echo "📋 Загрузка одного файла"
    echo "========================================="
    echo "URL: $url"
    echo "Директория: $output_dir"
    echo "========================================="
    
    download_single_file "$url" "$output_dir" "$min_size"
}

# Показать помощь
show_help() {
    echo "Использование:"
    echo "  $0 URL_PREFIX START END [OUTPUT_DIR] [EXTENSION] [MIN_SIZE]"
    echo "  $0 -f FILE_WITH_URLS [OUTPUT_DIR] [MIN_SIZE]"
    echo "  $0 -u SINGLE_URL [OUTPUT_DIR] [MIN_SIZE]"
    echo "  $0 -h"
    echo ""
    echo "Режимы:"
    echo "  1. Паттерн: загрузка patch0.tar.gz ... patchN.tar.gz"
    echo "     Пример: $0 'https://example.com/files/' 0 50 ./downloads tar.gz 1000000"
    echo ""
    echo "  2. Файл: загрузка из файла со списком URL (по одному на строку)"
    echo "     Пример: $0 -f urls.txt ./downloads 1000000"
    echo ""
    echo "  3. Один URL: загрузка одного файла"
    echo "     Пример: $0 -u 'https://example.com/file.zip' ./downloads 1000000"
    echo ""
    echo "Параметры:"
    echo "  OUTPUT_DIR - директория для сохранения (по умолчанию ./downloads)"
    echo "  MIN_SIZE   - минимальный размер в байтах (по умолчанию 1000000 = 1MB)"
}

# Главная функция
main() {
    # Проверка на помощь
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_help
        exit 0
    fi
    
    # Режим из файла
    if [ "$1" = "-f" ]; then
        if [ $# -lt 2 ]; then
            echo -e "${RED}❌ Ошибка: укажите файл с URL${NC}"
            show_help
            exit 1
        fi
        url_file=$2
        output_dir=${3:-./downloads}
        min_size=${4:-1000000}
        download_from_file "$url_file" "$output_dir" "$min_size"
    
    # Режим одного URL
    elif [ "$1" = "-u" ]; then
        if [ $# -lt 2 ]; then
            echo -e "${RED}❌ Ошибка: укажите URL${NC}"
            show_help
            exit 1
        fi
        single_url=$2
        output_dir=${3:-./downloads}
        min_size=${4:-1000000}
        download_single_url "$single_url" "$output_dir" "$min_size"
    
    # Режим паттерна
    else
        if [ $# -lt 3 ]; then
            echo -e "${RED}❌ Ошибка: недостаточно параметров${NC}"
            show_help
            exit 1
        fi
        download_by_pattern "$1" "$2" "$3" "$4" "$5" "$6"
    fi
}

# Запуск
main "$@"
