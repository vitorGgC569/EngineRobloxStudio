# Snack Roll — Diner & Race Club

Recriação do ciclo de **comer → crescer → rolar → romper fitas → comprar comidas melhores**, inspirado em [Get Fat to Break Tape](https://www.roblox.com/pt/games/75568173037446/Get-Fat-to-Break-Tape) e na captura fornecida. Código, cenário, modelos de comidas, mascotes e identidade próprios. Projeto separado do Aetherworks.

## Jogar

Abra `snackroll.rbxlx` no Roblox Studio e pressione Play.

| Controle | Ação |
|---|---|
| WASD / mouse / espaço | Andar, câmera e pular |
| E ou botão de comida | Comer |
| R ou entrada da pista | Começar a rolar |
| R durante a corrida | Encerrar e recolher os ganhos |
| F / P / L / B | Comidas / pets / placar ao vivo / loja Robux |
| Q perto de um expositor | Abrir o catálogo correspondente |

Dez mordidas do cookie inicial dão 40 de peso. A primeira corrida então rompe três fitas e rende 51 moedas: suficiente para comprar o donut de 50 moedas. O peso é permanente entre corridas; cada tentativa recebe uma reserva de energia igual ao peso atual.

## Implementado

- Restaurante com piso xadrez, chef mascote remodelado, balcão, mesas, luminárias, murais e vitrines 3D.
- Crescimento do corpo, comida equipada, rolagem animada e câmera de corrida.
- 36 barreiras de resistência crescente em jardim, vale doce e circuito cósmico.
- Oito comidas regulares, pets com silhuetas e acessórios próprios, animação da comida chegando à boca e partículas de migalha.
- Placar ao vivo dos três maiores pesos e ranking da sala ordenado pelo peso atual.
- Loja permanente preparada com dois passes: Raposa Estelar + Cookie Prisma + Poeira de Estrelas; Dragão Cacau + Waffle de Cacau + Brasa de Canela. Compras são confirmadas pelo servidor e os itens só são liberados após a confirmação do Roblox.
- Dois slots iniciais; mais um a cada dois renascimentos, até cinco.
- Renascimento: reinicia peso, moedas e comidas; mantém pets e recordes. Ganho base +50% e moedas da corrida +15% por renascimento.
- Auto comer desbloqueado na comida 3; auto rolar no renascimento 1; ambos param após cinco minutos sem atividade manual.
- Quatro rastros liberados por progressão e dois rastros de partículas exclusivos dos passes; vitórias ao completar a pista e bônus de chegada.
- Presente diário com sequência de até sete dias e presentes aos 1, 5, 15 e 30 minutos ativos. Renovação à meia-noite UTC.
- Menus recolhidos por padrão, modelos 3D no catálogo, feedback visual e áudio da biblioteca da engine.
- Perfis via Forge.Save, validação de payload e limites de frequência via Forge.Net. Compras, energia, relógio e premiação pertencem ao servidor.

## Uso da engine

`Forge.Net`, `Forge.Save`, `Forge.UI`, `Forge.Audio`, `Forge.Telemetry`, `Forge.Testing` e `WorldKit.Build`.

Novo componente reutilizável: `forge/luau/Forge/Progression/BarrierRun.lua`. Recebe uma pista declarativa, energia e passos de tempo; resolve barreiras e premiação sem depender do tema. O estado encerrado não produz novos ganhos. A matemática de obstáculos foi separada da apresentação deste jogo.

## Build e verificação

```powershell
rojo build games/snackroll/default.project.json --output games/snackroll/snackroll.rbxlx
python rqe.py studio restart games/snackroll/snackroll.rbxlx .
python rqe.py studio call bridge.install_client
python games/snackroll/validate_runtime.py
```

O teste abre um jogador real pelo Studio Bridge e usa cliques na UI: comer, correr, comprar donut, resgatar diário, adotar/equipar/guardar pet e conferir os ganhos. Nenhuma moeda ou progressão é injetada. Os testes matemáticos internos são identificados separadamente.

Cada execução grava uma pasta própria `artifacts/play-*/`: o recibo `runtime.json` vincula o hash do build às capturas, identidade da sessão, efeitos observados e logs do servidor/cliente. `manifest.json` registra os hashes dos arquivos finalizados. `latest-play.json` é somente um ponteiro diagnóstico. É evidência de desenvolvimento; **não autoriza release**.

## Limites declarados

- Studio usa uma sessão temporária, sem salvamento, mostrada no HUD. O salvamento persistente fora do Studio está implementado, mas ainda precisa de teste de reconexão em uma experiência publicada.
- Multiplayer, dispositivos além de computador, balanceamento de longo prazo e progressão tardia ainda não foram validados com jogadores reais.
- Ranking é da sala, não global. Os IDs dos passes estão como `0`: a loja mostra esses itens como pendentes e não abre uma compra falsa. É preciso definir a experiência de destino e criar os dois passes no Creator Hub antes de ativar vendas. Não há código ou assets extraídos do jogo de referência, nem publicação automática.
- Os números são o balanceamento inicial desta recriação, não medições do jogo de referência.
- O descritor e os contratos de qualidade da engine estão presentes. A calibração visual gerada e a evidência de release ainda precisam ser completadas antes de uma aprovação de produção.
