# Verificação — 14/09/2026

- **STATICALLY_VALIDATED**: build Rojo e compilação Luau concluídos. Build SHA-256: `705b61e11fff50a5f3f81b48d17febd997d55531f97ec587bdd20d1379c8b154`.
- **RUNTIME_VALIDATED**: seis cenários internos passaram; zero erros do servidor e do cliente.
- **RUNTIME_VALIDATED**: jogador real, por cliques na UI e sem progressão injetada: 10 mordidas → 40 de peso → 3 fitas → 51 moedas → donut. Diário pago uma vez, adoção/equipamento e retirada de pet conferidos pelo ganho de peso.
- **VISUALLY_VALIDATED**: restaurante, cardápio, pets e pista capturados com identidade de janela/sessão e hashes verificados. Evidência: `artifacts/play-1789354964405714700/`.
- Suíte Python da engine: **1388 testes executados, nenhum erro/falha, 1 ignorado** (748,191 segundos). O build de regressão e o demo genérico também concluíram; não constituem evidência jogável de Snack Roll.
- A verificação genérica `rqe release .` da raiz ficou **BLOCKED** e pertence ao projeto da raiz. Seu build é diferente e não autoriza nem reprova uma publicação deste jogo. Esta entrega não é uma aprovação de produção nem uma publicação.
- **NOT_VALIDATED**: persistência em experiência publicada, multiplayer, percurso integral de progressão/rebirth, retenção e dispositivos além de computador.

O projeto foi deixado em Play Solo no Roblox Studio. O HUD identifica a sessão de Studio sem salvamento.
