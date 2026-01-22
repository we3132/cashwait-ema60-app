# CashWait EMA60 (U2/D5) – Android APK 자동 빌드

이 레포는 Flutter 앱을 **GitHub Actions로 자동 빌드**해서 APK를 뽑아주는 초간단 템플릿입니다.

## 폰에 설치까지 (가장 쉬운 루트)
1) 이 폴더 전체를 GitHub에 새 레포로 업로드
2) GitHub 레포 상단 **Actions** 탭 → 워크플로우 `Build Android APK` 실행(자동으로도 1회 실행됨)
3) 실행이 끝나면(초록색 체크) → 해당 실행 페이지에서 **Artifacts**의 `app-release-apk` 다운로드
4) 폰으로 APK 전송 후 설치
   - Android: 설정 → 보안 → **알 수 없는 앱 설치 허용**(Chrome/Files 등)

## 앱 동작
- 데이터: QQQ (stooq CSV)로 EMA60 계산
- 확인: U2 / D5
- 포지션은 앱에서 직접 선택(TQQQ / CASH)
- 결과: `내일 액션`을 한 화면에 표시

> 참고: 이 APK는 템플릿 기본 설정(디버그 키)로 서명되어 설치 가능합니다.
