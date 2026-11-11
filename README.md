# Token Bonfire

Claude Code와 Codex가 쓰는 토큰을 바탕화면의 모닥불로 보여 주는 macOS 앱입니다. 토큰을 쓰면 동전이 불에 떨어지고, 많이 쓸수록 불이 커집니다. 아래 숫자는 앱을 켠 뒤 태운 토큰 수입니다.

## 동작

- **집계**: `~/.claude/projects`와 `~/.codex/sessions`의 세션 기록에 새로 붙는 사용량만 읽습니다. 앱을 켠 순간 0에서 시작하고, 켜 둔 동안 계속 쌓이며, 초기화하거나 끄면 0이 됩니다. 값은 저장하지 않습니다.
- **세는 양**: 입력 + 캐시 쓰기 + 출력. 캐시 읽기는 기본으로 빼며 메뉴에서 포함할 수 있습니다.
- **불 단계**: 대기·약·중·강·폭주. 분당 토큰(캐시 읽기 제외)이 1.5만·5만·12만을 넘을 때 중·강·폭주가 됩니다. 한꺼번에 들어온 양은 15초쯤에 걸쳐 나눠 탑니다.
- **숫자**: 동전이 불에 들어갈 때 오릅니다. 1000 미만은 정수, 그 위는 K·M·B·T.
- **읽는 내용**: 사용량 숫자와 시각만 읽습니다. 대화 내용은 쓰지 않고, 네트워크 연결도 없습니다.

불을 끌어 옮기고, 불이나 메뉴바 아이콘을 눌러 설정을 엽니다: 초기화, 크기, 집계 대상, 캐시 읽기 포함, 숫자 표시, 로그인 시 실행, 미리보기, 화면 오른쪽 아래로.

## 빌드

macOS 13 이상과 Xcode Command Line Tools가 필요합니다. 외부 의존성은 없습니다.

```sh
bash scripts/build.sh    # dist/TokenBonfire.app
bash scripts/test.sh
```

화면 없이 확인하는 명령:

```sh
BIN=dist/TokenBonfire.app/Contents/MacOS/TokenBonfire
$BIN --scan 30                                   # 30초 동안 잡힌 실제 사용량
$BIN --render out.png --tier 3 --seconds 5       # 강 단계 한 장(2배 PNG)
$BIN --render out.png --tokens 120000 --seconds 6
```

## 구조

- `Sources/TokenUsage.swift`: 세션 기록 해석(Claude 응답 중복 제거, Codex 누적값 차이)과 파일 따라 읽기.
- `Sources/BurnModel.swift`: 들어온 토큰을 나눠 태우는 속도, 불 단계, 숫자 표기.
- `Sources/BonfireRenderer.swift`: 구운 시트 읽기, 동전 낙하, 한 장으로 합치기.
- `Sources/BonfireView.swift`, `Sources/AppDelegate.swift`: 창, 끌기, 메뉴, 설정.
- `Resources/`: 불 11단계 × 90장(160×180, 초당 30장), 동전 24장, 숫자 글리프, `manifest.json`.
- `tools/bake/`: 그림을 다시 굽는 도구. `tools/bake/pixelfx`에 pixelfx를 두고 `node tools/bake/bake.mjs`.

불 단계 기준과 캐시 포함 배율(40배)은 2026-11 사용 기록 3일치로 잡은 값이며 `BurnModel.swift`에 있습니다.

## 라이선스

코드는 MIT. 그림의 출처는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있습니다.
