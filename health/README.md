# 1. 다운로드 후 실행권한
chmod +x health-sync.sh

# 2. 같은 디렉토리에 .env 생성
echo 'AIRTABLE_API_KEY=patXXXXXXXXXXXX.XXXXXXXX...' > .env
chmod 600 .env

# 3. 실행
./health-sync.sh /절대/경로/2026/05/2026-05-27.md
