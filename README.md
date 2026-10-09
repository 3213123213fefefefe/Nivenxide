# Hydroxide Local + Vanguard Tracker

Copia local do Hydroxide (zyu/hydroxide) com painel passivo de timers Vanguard.
Licenca original preservada em HYDROXIDE_LOCAL/LICENSE; consulte-a para redistribuicao.

## Instalar
Extraia HYDROXIDE_LOCAL na pasta workspace do executor. Execute:

```lua
loadstring(readfile("HYDROXIDE_LOCAL/start.lua"))()
```

Abra a aba **Cooldowns**. Em Configurar skill, selecione a habilidade e ajuste
Cooldown (segundos). Blade Crash tambem tem Duracao do efeito (segundos).
Cada skill tem seu proprio nome no painel e opcao Rastrear.
Em Painel e aparencia, configure cores, 0/1/2 casas decimais, visibilidade das
skills sem CD ativo, efeito e reinicio a cada ativacao. O reinicio esta desligado
por padrao para cliques repetidos nao prolongarem o cooldown.
Clique Mostrar painel de timers para ativar Status Effects; arraste o painel
para posicionar. As configuracoes ficam nos perfis de Config: crie/salve um perfil
e carregue-o ou configure autoload para recuperar seus ajustes.
Skills: Brandish, Puncture, Azure Ignition e Blade Crash. Confirme em jogo se
essas sao as skills da sua classe; os nomes vieram da lista do codigo original.

## Medir sem inventar tempos
Os campos com 0 indicam tempo desconhecido. Use uma skill e veja se o painel
registra o uso. Se nao registrar, selecione a skill e clique em Registrar uso
imediatamente depois de uma ativacao bem-sucedida.
Quando conseguir usa-la novamente, clique em Skill ficou pronta: medir CD.
Para Blade Crash, clique em Efeito Blade Crash acabou: medir assim que o efeito
visual/bonus terminar. Repita algumas vezes para conferir e ajuste os segundos.
A medicao inclui seu tempo de reacao. Nao use a medicao caso a ativacao falhe.
As configuracoes podem ser salvas pelo sistema de perfis existente do Hydroxide.

## Limites
Tool.Activated indica uma tentativa local: o servidor pode recusar a habilidade.
Depois de configurados, os contadores sao ESTIMATIVAS; nao consultam o servidor.
Nao ha deteccao automatica confirmada de fim do efeito. O timer de efeito inicia
no uso, portanto atrasos de animacao tambem podem exigir ajuste manual.
O tracker nao aciona skills, nao dispara remotes e nao altera cooldowns.
Status Effects deve ficar ligado para mostrar os contadores. Desligar apenas
Status Effects esconde o painel, mas o tracker continua registrando usos.
Desligar Ativar rastreamento limpa e pausa o tracker.
Morte (quando Humanoid ja existe), remocao e troca de personagem limpam timers.

## Validacao
Modulo testado com Lua 5.4 e objetos simulados: tempos desconhecidos, medicao,
medicao duplicada, cliques repetidos, valor negativo, reset e desativacao,
selecao de skill, campos visiveis, configuracao separada, nomes, decimais,
ocultacao de inativos/efeito, reinicio e desativacao individual.
Integracao conferida por inspecao de escopo. Sem teste no Roblox/Potassium.
O restante do Hydroxide foi preservado, sem validacao dos seus demais recursos.

## GitHub
Pacote organizado para envio na raiz de um repositorio novo.
A instalacao permanece LOCAL: publicar no GitHub nao transforma readfile em
carregamento HTTP. Para usar, baixe o ZIP do repositorio e extraia os arquivos.
Nao coloque tokens, senhas ou cookies no repositorio nem no executor.
