# Aetherworks: implementação local — 9 de setembro de 2026

Build: `aetherworks.rbxlx`. Esta revisão não foi publicada como atualização da experiência Roblox.

## Entregas desta revisão

- Kit original de dezesseis malhas: cristais lapidados, carcaças, brocas, engrenagens, tubulações, estruturas e ferramentas. Templates publicados carregados no Studio e clonados pela engine.
- Máquinas com detalhes e evolução visual; arsenal com oficina, balcão e exposição. Prévia 3D da melhoria seguinte e dos equipamentos nos menus.
- Destaque de alvo começa desativado e só contorna um inimigo selecionado. Placa da torre fora da moldura. Guarnição e reator de bônus separados em um anexo com passagem aberta. Coletor convertido em cofre com funil, visor e bandeja; afastado do farol.
- Casa Aurora comprável em todas as ilhas, com mesmo projeto. Cinco andares comprados em sequência, exigindo renascimentos 0/1/2/3/5 e liberando exatamente dois espaços por andar.
- Dez pets com modelos 3D, duas categorias de bônus, adoção garantida por coroas, cinco níveis individuais e ocupação persistente. Dois pets iniciais incluídos na compra do lote. Menus em U, visita à casa e elevadores para andares construídos.
- Bônus apenas de pets hospedados; produção automática e offline, ou valor da mineração manual. Um mesmo pet não pode acumular bônus em dois espaços. Casa, andares e pets sobrevivem ao renascimento.
- Coleção em C: descobertas permanentes, três projetos de chefes, fabricação e especializações, semanais e decoração.
- Cinco funções de tropa, composição por espaço, rotas, prioridades e relés de cura. Rodadas locais com honra cosmética.
- Torre: decisões entre ondas, foco de alvo, saque adicional arriscado e implementação de dupla com recompensas por participante. Recuperação de vida respeita pesquisa e especialização de cada membro.
- Eventos de onboarding e marcos preparados no AnalyticsService; envio é pulado no Studio.

## Evidência e limites

| Verificação | Resultado | Classificação |
|---|---|---|
| Compilação Luau e Rojo do projeto Aetherworks | Concluídos | STATICALLY_VALIDATED |
| Engine, suíte Python ampla | 1.388 testes; 14 falhas/erros ligados ao hash de schema desatualizado; hash corrigido, 60 testes afetados e novos passaram na repetição direcionada | STATICALLY_VALIDATED |
| Suíte interna no Studio 0.738 | 22 cenários aprovados, incluindo compras, bloqueios, preservação dos dados e bônus dos pets | RUNTIME_VALIDATED |
| Casa pelo menu com jogador real do Studio | Compra do lote, construção de andares, adoção, melhoria, mudança e retirada de pet; produção medida de ×1,06 para ×1,185 e de volta a ×1,06 ao retirar a coruja | RUNTIME_VALIDATED |
| Revisão de imagens | Casa, modelos dos pets, interfaces, arsenal, coletor, guarnição e entrada da torre fotografados com câmera e sessão vinculadas | VISUALLY_VALIDATED |
| Dupla nesta revisão | Teste nativo multiplayer expirou antes de obter runtime verificável; sem alegação de cooperação executada | NOT_VALIDATED |

Relatórios e capturas: `artifacts/habitat-runtime.json`, `artifacts/art-runtime.json`, `artifacts/refinement-coop.json`, `artifacts/refinement-regression.log` e `artifacts/refinement-unittest.log`. O recibo `artifacts/refinement-receipt.json` vincula hashes do código, build e evidências; **não autoriza release**.

Os perfis avançados usados nos testes são fixtures locais e não persistentes (`battle-lab`), não progresso conquistado. O teste de preservação dos pets verifica estrutura serializável e renascimento; não comprova DataStore entre servidores publicados. A validação de combate multiplayer anterior pertence ao build anterior, sem estender automaticamente suas conclusões a este.

NOT_VALIDATED: DataStore público, entrega de analytics em produção, economia ao longo de semanas, experiência com lotação máxima, latência de internet e publicação. Ranking global, pareamento por força e temporadas globais não estão implementados. Nenhum dos recibos locais substitui o manifesto imutável exigido para lançamento.
