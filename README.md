# Token Bonfire

**Claude Code와 Codex가 태우는 토큰을 바탕화면 모닥불로 보여 주는 macOS 앱.**

> [!NOTE]
> 실행 파일은 배포하지 않습니다. macOS 13 이상에서 직접 빌드해 씁니다. 빌드한 앱은 ad-hoc 서명이며 Apple 공증을 받지 않았습니다. Apple Silicon에서 실행을 확인했습니다.

```sh
git clone https://github.com/tinkerer0/token_bonfire.git
cd token_bonfire
bash scripts/build.sh
open dist/TokenBonfire.app
```

Xcode Command Line Tools만 있으면 됩니다. 외부 의존성은 없습니다.

![대기부터 폭주까지 다섯 단계의 모닥불](docs/demo.gif)

토큰을 쓰면 동전이 불에 떨어지고, 많이 쓸수록 불이 커집니다. 아래 숫자는 앱을 켠 뒤 태운 토큰 수입니다.

## 사용법

불을 끌어서 원하는 자리에 둡니다. 불을 우클릭하거나 메뉴바의 불꽃 아이콘을 누르면 초기화, 크기(0.75~3배), 집계 대상(Claude Code·Codex), 숫자 표시, 로그인 시 실행, 단계 미리보기를 고를 수 있습니다. 불이 없는 투명한 자리의 클릭은 아래 창으로 넘어갑니다.

## 집계 방식

- 앱을 켠 순간 0에서 시작합니다. 켜 둔 동안 계속 쌓이고, 초기화하거나 끄면 0이 됩니다.
- 세는 양은 입력 + 캐시 쓰기 + 출력입니다. 캐시에서 다시 읽은 입력은 세지 않습니다.
- 불은 대기·약·중·강·폭주 다섯 단계입니다. 분당 토큰이 1.5만·5만·12만을 넘으면 중·강·폭주가 됩니다.
- 한꺼번에 들어온 양은 15초쯤에 걸쳐 동전으로 나눠 떨어지고, 숫자는 동전이 불에 들어갈 때 오릅니다.
- 숫자는 1000 미만은 정수, 그 위는 K·M·B·T로 줄여 씁니다.

세션 기록에서 사용량 숫자와 시각만 읽으며 네트워크 연결은 없습니다. 자세한 내용은 [PRIVACY.md](PRIVACY.md)에 있습니다.

## 개발

```sh
bash scripts/test.sh
BIN=dist/TokenBonfire.app/Contents/MacOS/TokenBonfire
$BIN --scan 30                              # 30초 동안 잡힌 사용량
$BIN --render out.png --tier 3 --seconds 5  # 화면 없이 한 장 그리기
$BIN --demo frames --seconds 2              # 단계별 낱장
```

토큰 집계는 `Sources/TokenUsage.swift`, 불 단계와 숫자 표기는 `Sources/BurnModel.swift`, 그림 합성은 `Sources/BonfireRenderer.swift`에 있습니다. `Resources/`의 그림은 `tools/bake/pixelfx`에 [pixelfx](https://github.com/tinkerer0/pixelfx)를 두고 `node tools/bake/bake.mjs`로 다시 만들 수 있습니다.

## Feedback

제가 이런 분야를 접한 지 얼마 안 돼서 부족한 점이 많습니다. 고칠 점이나 알려주실 내용이 있다면 issue나 PR로 남겨주시면 너무 감사하겠습니다.

## License

코드는 [MIT](LICENSE)입니다. 그림은 pixelfx(MIT)로 그렸으며 출처와 라이선스는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있습니다.
