# Blade 23 Lite — versão alternativa de teste

Esta edição carrega o Blade/Sigil e o ROT com suas dependências e uma interface menor. O loader normal continua disponível. A correção do force reset das fornecedoras está nas duas edições.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/lite/loader.lua"))()
```

Use Unload na edição aberta antes de executar a outra. Apenas uma edição pode estar ativa no mesmo cliente.

## O que permanece

- Todas as etapas, configurações e seleção manual de etapa do Blade/Sigil; XP de espada, três socos normais, treino de mana, compras, trainers e Khei.
- ROT receptor e fornecedor, seleção de alts, fila local, contagem, retomada após hop/rejoin, Play, recuperação da jail e ciclo após wipe.
- Allies, reconhecimento das contas do mesmo PC, modo 23, proximity e illusionist checks, Stay in Server e retomada após Play manual.
- Anti-AFK, ativado por padrão; AutoBard, AutoDialogue, controles de mana, coleta de itens/silver e proteções usadas pelo bot.
- Save, Load, Auto Load, autosave por conta, backups de configuração, tecla do menu, Unload e alertas/webhook do bot.

## O que deixa de carregar

ESP, modificações cosméticas do leaderboard/menu do Roblox, skins, macros, editores de caminhos, chat/logs de interface, outros bots e diagnósticos periódicos de RAM. Os módulos de progressão, ROT, diálogos, pouso e coordenação são copiados do original, com verificação de integridade no gerador.

O runtime tem aproximadamente 0,89 MB, comparado a 2,68 MB da edição completa: cerca de **67% menos código-fonte**. Isso não mede a redução de RAM do processo do Roblox. Há menos módulos, interface e observadores extras, mas o consumo real e a estabilidade precisam ser comparados no executor.

## Desempenho

Em **Settings → Desempenho Lite**, os padrões são:

- 20 FPS com a janela ativa e 15 FPS em segundo plano, ambos ajustáveis.
- Qualidade gráfica mínima.
- Renderização 3D suspensa quando a janela perde o foco e restaurada ao voltar. A execução do bot continua.

As alterações são aplicadas por eventos de foco/configuração, sem um loop por frame. Desativar o modo ou executar Unload restaura a qualidade anterior e o limite de FPS anterior quando o executor oferece `getfpscap`. Anti-AFK conserva o mecanismo original e requer `getconnections`.

## Configurações e progresso

Os perfis, autoload, preferências, aliados e atalhos da Lite usam arquivos separados. Na primeira execução, as preferências automáticas do Blade, os aliados e a tecla do menu da edição completa são copiados, quando disponíveis, sem sobrescrever os originais. Depois, cada edição salva suas próprias configurações. Perfis nomeados da edição completa não são importados automaticamente: crie e selecione o autoload desejado na Lite.

O progresso confirmado e os arquivos de coordenação entre contas continuam compartilhados, para manter o reconhecimento e as filas entre contas usando ambas as edições. A retomada automática da Lite chama o loader da própria Lite.

## Force reset das fornecedoras

A opção de perder vida chama o mesmo `sResult10.kill()` usado na recuperação de jail/combate, sem aguardar a tag Danger nem tentar dano de queda. A ação respeita o ponto P14, a condição de fornecedora, Stop, Unload, pausa no menu, transporte e jail.

Se o personagem continuar vivo e o servidor não responder, repete a solicitação a cada três segundos. Morte, troca de personagem ou perda de vida confirmada interrompem as tentativas daquele pedido. A mensagem de confirmação só aparece após redução de `Lives`; enviar o reset não é tratado como confirmação.

## Manutenção e validação

O arquivo `sentinel.lua` desta pasta é gerado a partir de `../sentinel.lua`, com os pequenos componentes de `parts/`. Para reconstruir, use o parser oficial do Luau:

```sh
python3 blade23/tools/build_lite.py --ast /caminho/luau-ast
LUAU_BIN=/caminho/luau LUAU_AST=/caminho/luau-ast python3 -m unittest discover -s blade23/tests
```

`manifest.json` registra os hashes da origem, do resultado e dos módulos preservados. Os testes executam funções Luau com serviços simulados, incluindo persistência, retomada, anti-AFK, economia gráfica e o force reset. A compilação e esses testes não substituem o teste em jogo com o executor, ping e número de contas reais.
