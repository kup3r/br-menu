from datetime import datetime, timezone
from html import escape
from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import (Message, CallbackQuery, PreCheckoutQuery, InlineKeyboardButton,
    InlineKeyboardMarkup, LabeledPrice, BufferedInputFile)
from .service import LicenseError

class Form(StatesGroup):
    create_keys = State()
    find_key = State()
    extend_key = State()
    new_plan = State()

def keyboard(rows):
    return InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text=text, callback_data=data) for text,data in row] for row in rows])

def stamp(value):
    return datetime.fromtimestamp(value, timezone.utc).strftime('%d.%m.%Y %H:%M UTC') if value else 'с первой активации'

def key_text(service, license):
    return (f'<code>{escape(service.reveal(license))}</code>\n'
        f'Состояние: {escape(license.status)}\nСрок: {license.days} дней · устройств: {license.max_devices}\n'
        f'Действует до: {stamp(license.expires_at)}\nВведи ключ в меню приложения.')

def build_dispatcher(service, bot: Bot):
    dp=Dispatcher();r=Router();r.message.filter(F.chat.type=='private');r.callback_query.filter(F.message.chat.type=='private')
    home=keyboard([[('Купить доступ','shop'),('Мои ключи','mine')],[('Поддержка','support')]])
    admin_home=keyboard([[('Создать ключи','a:keys'),('Найти ключ','a:find')],
        [('Тарифы','a:plans'),('Статистика','a:stats')],[('Платежи / возвраты','a:payments'),('Все ключи','a:recent:0')],[('Выйти в магазин','home')]])

    async def send_plans(message, target=None):
        plans=await service.plans()
        if not plans:
            await message.answer('Продажи пока не открыты: администратор ещё не добавил тарифы.');return
        rows=[[(f'{p.title} · {p.days} дн. · ⭐ {p.stars}', f'buy:{p.id}')] for p in plans]
        await message.answer('Выбери тариф. Срок нового ключа начинается с первой активации.\n'
            +('Оплата продлит выбранный ключ.' if target else 'Разовая покупка, без автоматических списаний.'), reply_markup=keyboard(rows))

    async def admin_key(message,id):
        license=await service.get_license(message.chat.id,id)
        rows=[[('Продлить',f'a:extend:{id}'),('Сброс устройств',f'a:resetask:{id}')],
            [('Заблокировать',f'a:block:{id}'),('Разблокировать',f'a:unblock:{id}')],[('Админ-панель','a:home')]]
        await message.answer(key_text(service,license),reply_markup=keyboard(rows))

    @r.message(CommandStart())
    async def start(m: Message,state: FSMContext):
        await state.clear()
        await m.answer('BR · Подписки и ключи\nКупи доступ или посмотри свои ключи.',reply_markup=home)
        if m.from_user.id in service.settings.admin_ids:
            await m.answer('У тебя есть доступ администратора.',reply_markup=keyboard([[('Открыть админ-панель','a:home')]]))

    @r.message(Command('admin'))
    async def admin(m: Message,state: FSMContext):
        try: service.admin(m.from_user.id)
        except LicenseError:
            await m.answer('Нет доступа.');return
        await state.clear();await m.answer('Админ-панель',reply_markup=admin_home)

    @r.message(Command('cancel'))
    async def cancel(m: Message,state: FSMContext):
        await state.clear();await m.answer('Действие отменено.',reply_markup=home)

    @r.message(Command('terms'))
    async def terms(m: Message):
        await m.answer(escape(service.settings.terms))

    @r.message(Command('support','paysupport'))
    async def support(m: Message):
        await m.answer('Поддержка по доступу и оплатам: '+escape(service.settings.support_url))

    @r.callback_query(F.data.in_({'home','shop','terms_accept','mine','support'}))
    async def user_menu(c: CallbackQuery,state: FSMContext):
        await c.answer();await state.clear()
        if c.data=='home': await c.message.answer('Главное меню',reply_markup=home)
        elif c.data=='support': await c.message.answer('Поддержка: '+escape(service.settings.support_url))
        elif c.data=='shop':
            await c.message.answer(escape(service.settings.terms),reply_markup=keyboard([[('Принимаю условия · выбрать тариф','terms_accept')]]))
        elif c.data=='terms_accept':
            await service.accept_terms(c.from_user.id);await send_plans(c.message)
        else:
            licenses=await service.my_keys(c.from_user.id)
            if not licenses: await c.message.answer('У тебя пока нет покупок.',reply_markup=home)
            for license in licenses:
                await c.message.answer(key_text(service,license),reply_markup=keyboard([[('Продлить этот ключ',f'renew:{license.id}')]]))

    @r.callback_query(F.data.startswith('renew:'))
    async def renew(c: CallbackQuery,state: FSMContext):
        await c.answer();await state.clear()
        id=c.data.split(':',1)[1]
        licenses=await service.my_keys(c.from_user.id)
        if not any(x.id==id and x.status=='active' for x in licenses):
            await c.message.answer('Этот ключ нельзя продлить.');return
        await state.update_data(renew_id=id)
        await send_plans(c.message,id)

    @r.callback_query(F.data.startswith('buy:'))
    async def buy(c: CallbackQuery,state: FSMContext):
        await c.answer()
        try:
            target=(await state.get_data()).get('renew_id')
            order=await service.create_order(c.from_user.id,c.data.split(':',1)[1],target)
            await bot.send_invoice(chat_id=c.from_user.id,title=order.title,
                description=f'Доступ на {order.days} дней. '+('Продление выбранного ключа.' if target else 'Ключ выдаётся после подтверждения оплаты.'),
                payload=order.id,currency='XTR',provider_token='',prices=[LabeledPrice(label=order.title,amount=order.stars)],
                start_parameter='order_'+order.id.replace('-',''))
            await state.clear()
        except LicenseError as e: await c.message.answer(e.message)

    @r.pre_checkout_query()
    async def checkout(q: PreCheckoutQuery):
        try:
            await service.checkout(q.from_user.id,q.invoice_payload,q.currency,q.total_amount)
        except LicenseError as e:
            await q.answer(ok=False,error_message=e.message)
        else: await q.answer(ok=True)

    @r.message(F.successful_payment)
    async def payment(m: Message):
        p=m.successful_payment
        license=await service.receive_payment(m.from_user.id,p.invoice_payload,p.currency,p.total_amount,p.telegram_payment_charge_id)
        await m.answer('Оплата получена. Сохрани ключ:\n'+key_text(service,license),reply_markup=home)

    @r.message(F.refunded_payment)
    async def refunded(m: Message):
        await service.record_refund(m.refunded_payment.telegram_payment_charge_id,m.from_user.id)
        await m.answer('Возврат платежа учтён. Доступ по связанному ключу приостановлен. По остальным продлениям обратись в поддержку.')

    @r.callback_query(F.data.startswith('a:'))
    async def admin_click(c: CallbackQuery,state: FSMContext):
        # Every admin callback rechecks identity; no trust in button visibility/FSM.
        try: service.admin(c.from_user.id)
        except LicenseError:
            await c.answer('Нет доступа',show_alert=True);return
        await c.answer()
        parts=c.data.split(':');action=parts[1];id=parts[2] if len(parts)>2 else ''
        try:
            if action=='home':
                await state.clear();await c.message.answer('Админ-панель',reply_markup=admin_home)
            elif action=='keys':
                await state.set_state(Form.create_keys)
                await c.message.answer('Пришли: дни количество устройства старт\nНапример: <code>30 10 1 activation</code>\n'
                    'activation — отсчёт с активации, now — с создания. До 100 ключей. Отмена: /cancel')
            elif action=='find':
                await state.set_state(Form.find_key);await c.message.answer('Пришли полный ключ. Отмена: /cancel')
            elif action=='extend':
                await state.set_state(Form.extend_key);await state.update_data(key_id=id)
                await c.message.answer('На сколько дней продлить? От 1 до 3650. Отмена: /cancel')
            elif action=='resetask':
                await c.message.answer('Сбросить привязки и отключить все сессии этого ключа?',reply_markup=keyboard([[('Да, сбросить',f'a:reset:{id}'),('Отмена','a:home')]]))
            elif action in {'block','unblock','reset'}:
                await service.manage_key(c.from_user.id,id,action);await admin_key(c.message,id)
            elif action=='recent':
                page=int(id or '0'); keys=await service.recent_keys(c.from_user.id,page)
                rows=[[(f'{service.reveal(k)[-8:]} · {k.days} дн. · {k.status}',f'a:view:{k.id}')] for k in keys[:20]]
                navigation=[]
                if page: navigation.append(('‹ Назад',f'a:recent:{page-1}'))
                if len(keys)>20: navigation.append(('Далее ›',f'a:recent:{page+1}'))
                if navigation: rows.append(navigation)
                rows.append([('Админ-панель','a:home')])
                await c.message.answer('Все ключи · страница '+str(page+1),reply_markup=keyboard(rows))
            elif action=='view': await admin_key(c.message,id)
            elif action=='stats': await c.message.answer(await service.stats(c.from_user.id),reply_markup=admin_home)
            elif action=='plans':
                plans=await service.plans(all=True)
                rows=[[(f'{"✅" if p.active else "⛔"} {p.title} · {p.days} дн. · ⭐ {p.stars}',f'a:plan:{p.id}')] for p in plans]
                rows += [[('Добавить тариф','a:newplan')],[('Назад','a:home')]]
                await c.message.answer('Нажми тариф, чтобы открыть/закрыть продажи. Для новой цены создай новый тариф: старые счета сохраняют прежнюю цену.',reply_markup=keyboard(rows))
            elif action=='plan':
                await service.toggle_plan(c.from_user.id,id);await c.message.answer('Доступность тарифа изменена.',reply_markup=keyboard([[('Тарифы','a:plans')]]))
            elif action=='newplan':
                await state.set_state(Form.new_plan);await c.message.answer('Название | дни | цена Stars\nНапример: <code>Месяц | 30 | 150</code>\nОтмена: /cancel')
            elif action=='payments':
                payments=await service.payments(c.from_user.id)
                if not payments: await c.message.answer('Оплат пока нет.',reply_markup=admin_home)
                for p in payments:
                    await c.message.answer(f'Покупатель: <code>{p.user_id}</code> · ⭐ {p.stars}\n{stamp(p.created_at)} · {p.status}\nСчёт: <code>{p.order_id}</code>',
                        reply_markup=keyboard([[('Возврат / подтвердить',f'a:refundask:{p.order_id}')]]) if p.status=='paid' else None)
            elif action=='refundask':
                await c.message.answer('Полностью вернуть эту оплату Stars? Связанный ключ, включая продления, будет отключён.',
                    reply_markup=keyboard([[('Да, вернуть',f'a:refund:{id}'),('Отмена','a:home')]]))
            elif action=='refund':
                p=await service.prepare_refund(c.from_user.id,id)
                # Timeout/transport errors intentionally leave refund_pending:
                # never retry a money operation blindly or restore access on uncertainty.
                try:
                    await bot.refund_star_payment(user_id=p.user_id,telegram_payment_charge_id=p.charge_id)
                except Exception:
                    await c.message.answer('Возврат требует проверки: запрос не подтверждён. Доступ приостановлен. Проверь баланс/платёж; не повторяй возврат вслепую.');return
                await service.record_refund(p.charge_id,p.user_id)
                await c.message.answer('Stars возвращены, связанный ключ отключён.',reply_markup=admin_home)
        except LicenseError as e: await c.message.answer(e.message)
        except ValueError: await c.message.answer('Некорректная кнопка. Открой /admin заново.')

    @r.message(Form.create_keys)
    async def create_keys(m: Message,state: FSMContext):
        try:
            service.admin(m.from_user.id)
            days,count,devices,start=(m.text or '').split()
            if start not in {'activation','now'}: raise ValueError()
            keys=await service.create_keys(m.from_user.id,int(days),int(count),int(devices),start=='now')
        except (ValueError,LicenseError) as e:
            await m.answer(str(e) or 'Формат: 30 10 1 activation');return
        await state.clear()
        content='\n'.join(service.reveal(k) for k in keys)+'\n'
        await m.answer_document(BufferedInputFile(content.encode(),filename=f'keys-{days}days.txt'),caption=f'Создано {len(keys)} ключей на {days} дней. Старт: {start}.')
        await m.answer('Ключи сохранены в базе.',reply_markup=admin_home)

    @r.message(Form.find_key)
    async def find(m: Message,state: FSMContext):
        try: license=await service.find_key(m.from_user.id,m.text or '')
        except LicenseError as e: await m.answer(e.message);return
        await state.clear();await admin_key(m,license.id)

    @r.message(Form.extend_key)
    async def extend(m: Message,state: FSMContext):
        try:
            days=int(m.text or '')
            await service.manage_key(m.from_user.id,(await state.get_data())['key_id'],'extend',days)
        except (ValueError,LicenseError) as e: await m.answer(str(e) or 'Нужно число дней');return
        id=(await state.get_data())['key_id'];await state.clear();await admin_key(m,id)

    @r.message(Form.new_plan)
    async def new_plan(m: Message,state: FSMContext):
        try:
            service.admin(m.from_user.id)
            title,days,stars=[x.strip() for x in (m.text or '').split('|')]
            await service.add_plan(m.from_user.id,title,int(days),int(stars))
        except (ValueError,LicenseError) as e: await m.answer(str(e) or 'Формат: Месяц | 30 | 150');return
        await state.clear();await m.answer('Тариф добавлен, продажи открыты.',reply_markup=admin_home)

    dp.include_router(r)
    return dp
