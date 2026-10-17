# Observações desta integração

- **RUNTIME_VALIDATED** — `Forge.Net`, `Forge.Save` em memória de Studio, `Forge.UI`, `Forge.Audio`, `Forge.Testing` e `WorldKit.Build` compuseram um segundo gênero, sem depender de rotinas de Aetherworks. Comer/correr/comprar e o bônus de pets foram exercitados por cliques reais.
- **RUNTIME_VALIDATED** — Novo `Forge.Progression.BarrierRun`: resolve distância, resistência e premiação; seis cenários internos incluem divisão de tempo, encerramento, cancelamento, economia inicial e as duas regressões visuais abaixo. Esses testes internos não equivalem à progressão conquistada pelo jogador.
- **VISUALLY_VALIDATED** — `UIStroke` no modo contextual de um `TextButton` contorna o texto, prejudicando a leitura. Os botões deste jogo escolhem explicitamente `ApplyStrokeMode.Border`.
- **VISUALLY_VALIDATED** — Um cilindro orientado usado como `PrimaryPart` redefine a orientação do modelo quando recebe `PivotTo`. Comidas agora têm pivô sem rotação na origem, preservando os discos horizontais.
- **RUNTIME_VALIDATED** — A primeira corrida com 40 de peso rompe 3 fitas e paga 51 moedas; o donut custa 50. Equipar Pudim muda a mordida do donut de 10 para 11; guardar o pet volta a 10. O diário não paga duas vezes.
- **NOT_VALIDATED** — Persistência publicada, múltiplos jogadores simultâneos, progressão completa de renascimento e retenção com jogadores externos. Nenhuma afirmação de release se apoia em fixtures ou no diagnóstico genérico da raiz do repositório.

O comando `rqe release .` da raiz seleciona o projeto da raiz e controla o Studio. Não deve ser executado junto de um playtest de outro jogo. Para este projeto, use sempre um alvo explícito `games/snackroll`; recibos desse projeto só podem se associar ao hash do seu próprio build.
