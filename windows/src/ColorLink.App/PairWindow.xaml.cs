using System.ComponentModel;
using ColorLink.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace ColorLink.App;

public sealed partial class PairWindow : Window
{
    const string Manual = "手动输入地址";
    readonly LinkController _link;
    IReadOnlyList<DiscoveredPhone> _phones = [];
    bool _filling, _userPicked;

    public PairWindow(LinkController link)
    {
        _link = link;
        InitializeComponent();
        WindowHelper.Decorate(this, "配对手机 - ColorLink");
        SetTitleBar(TitleBar);
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter p)
        {
            p.IsResizable = false;
            p.IsMaximizable = false;
        }
        WindowHelper.SizeAndCenter(this, 440, 470);
        _link.PropertyChanged += OnLinkChanged;
        Closed += (_, _) => _link.PropertyChanged -= OnLinkChanged;
        FillPhones();
    }

    void OnLinkChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(LinkController.Discovered)) FillPhones();
    }

    void FillPhones()
    {
        var selected = PhonePicker.SelectedItem as string;
        _phones = _link.Discovered;
        _filling = true;
        PhonePicker.Items.Clear();
        foreach (var p in _phones) PhonePicker.Items.Add($"{p.Name}（{p.Endpoint.Host}）");
        PhonePicker.Items.Add(Manual);
        // 用户自己选过就保留；否则默认选发现的第一台
        int i = _userPicked && selected is not null ? PhonePicker.Items.IndexOf(selected) : 0;
        PhonePicker.SelectedIndex = i < 0 ? 0 : i;
        _filling = false;
        PhonePicker_SelectionChanged(PhonePicker, null!);
        SearchingText.Text = _phones.Count == 0 ? "局域网里还没发现手机，正在找…" : $"局域网里发现 {_phones.Count} 台手机";
    }

    DiscoveredPhone? SelectedPhone => PhonePicker.SelectedIndex >= 0 && PhonePicker.SelectedIndex < _phones.Count ? _phones[PhonePicker.SelectedIndex] : null;

    void PhonePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling) return;
        if (e is not null) _userPicked = true;
        AddressBox.Visibility = SelectedPhone is null ? Visibility.Visible : Visibility.Collapsed;
        UpdateButton();
    }

    void CodeBox_TextChanged(object sender, TextChangedEventArgs e) => UpdateButton();

    void UpdateButton() =>
        PairButton.IsEnabled = !Busy.IsActive && CodeBox.Text.Trim().Length == 6 && CodeBox.Text.Trim().All(char.IsAsciiDigit)
                               && (SelectedPhone is not null || AddressBox.Text.Trim().Length > 0);

    void CodeBox_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && PairButton.IsEnabled) Pair_Click(sender, e);
    }

    async void Pair_Click(object sender, RoutedEventArgs e)
    {
        Busy.IsActive = true;
        UpdateButton();
        ErrorBar.IsOpen = false;
        try
        {
            await _link.PairAsync(SelectedPhone, AddressBox.Text, CodeBox.Text);
            Close();
        }
        catch (Exception ex)
        {
            ErrorBar.Message = ex is PhoneException ? ex.Message : $"连不上手机：{ex.Message}";
            ErrorBar.IsOpen = true;
        }
        finally
        {
            Busy.IsActive = false;
            UpdateButton();
        }
    }
}
